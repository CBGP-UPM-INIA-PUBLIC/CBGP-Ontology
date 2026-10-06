#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the ontology for clerical slips BEFORE it is pushed, and says where
# each one is (class name and line number) so it can be fixed at source.
#
#   ruby check_ontology.rb                         # checks cbgp-application-ontology.owl next to this file
#   ruby check_ontology.rb some-other-file.owl
#   ruby check_ontology.rb --languages en,es,fr    # require more languages (default: en,es)
#   ruby check_ontology.rb --errors-only           # hide warnings
#
# Exit status: 0 = no errors (warnings alone do not fail), 1 = errors found,
# 2 = the file could not be read.
#
# Needs nothing but Ruby itself (standard library only) - no gems, no network,
# no database.
#
# ERRORS - fix these:
#   untagged_label        a label with no language tag (needs xml:lang="en" / "es").
#                         Untagged labels are invisible to the application.
#   empty_label           a blank label
#   missing_language      a class that has labels, but none in English or none in
#                         Spanish
#   form_incomplete       a form (a subclass of cbgp:forms) with no local:form-category,
#                         local:dbname or local:has-fields - it would never be listed
#   ui_text_placeholders  an interface text (a subclass of cbgp:ui-text) whose labels
#                         do not use the same %{names} in every language - the
#                         application would show a raw %{name} to the user
#   ui_text_characters    an interface text containing a back-tick, quote, < > or backslash (they
#                         would break the page the text is printed into)
#   conditional_requirement_incomplete
#                         a conditional requirement (a subclass of cbgp:conditional-requirement)
#                         missing its local:conditional-requirement-field, -when-field or
#                         -when-answer - the application could not apply it
#   conditional_requirement_unknown
#                         a conditional requirement, or a form's local:has-conditional-requirements,
#                         that points at a class that does not exist (typo in a field or answer name)
#   untagged_annotation   local:form-category / local:dbname written without
#                         xml:lang="en", unlike every other form. (This is what
#                         once made the European and Private project forms vanish
#                         from the menus.)
#
# WARNINGS - worth a look, do not fail:
#   duplicate_label       two labels in the same language on one class
#   untagged_comment      an rdfs:comment with no language tag. The application
#                         only shows comments in the user's language, so an
#                         untagged one is NOT shown to users - fine for an editor
#                         note such as "(Deprecated)", but if it is meant as help
#                         text, add xml:lang to it.
require 'rexml/document'
require 'optparse'

module OntologyCheck
  RDF_NS   = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#'
  RDFS_NS  = 'http://www.w3.org/2000/01/rdf-schema#'
  OWL_NS   = 'http://www.w3.org/2002/07/owl#'
  LOCAL_NS = 'urn:local:'
  XML_NS   = 'http://www.w3.org/XML/1998/namespace'
  DEFAULT_LANGUAGES = %w[en es].freeze
  FORM_REQUIRED = { 'form-category' => 'local:form-category', 'dbname' => 'local:dbname',
                    'has-fields' => 'local:has-fields' }.freeze
  TAGGED_BY_CONVENTION = %w[dbname form-category].freeze

  Finding = Struct.new(:severity, :code, :subject, :detail, keyword_init: true) do
    def to_s
      "#{severity.to_s.upcase.ljust(7)} #{code} #{subject}: #{detail}"
    end
  end

  # What one <owl:Class> says, reduced to what the checks need.
  # labels/comments: [{ text:, lang: }]   props: { 'dbname' => [{ text:, lang: }], ... }
  Klass = Struct.new(:name, :labels, :comments, :supers, :props, keyword_init: true)

  # @return [Array<Finding>] errors first, then warnings, each group sorted by class
  def self.check_xml(xml, languages: DEFAULT_LANGUAGES)
    check_classes(parse(xml), languages: languages)
  end

  def self.check_file(path, languages: DEFAULT_LANGUAGES)
    check_xml(File.read(path, encoding: 'UTF-8'), languages: languages)
  end

  def self.errors(findings)
    findings.select { |f| f.severity == :error }
  end

  # { 'ClassName' => line number } so a finding can say where to look.
  def self.line_numbers(path)
    lines = {}
    File.foreach(path, encoding: 'UTF-8').with_index(1) do |line, i|
      m = line.match(%r{<owl:Class rdf:about="[^"]*[#/]([^"#/]+)"})
      lines[m[1]] ||= i if m
    end
    lines
  rescue SystemCallError
    {}
  end

  def self.parse(xml)
    doc = REXML::Document.new(xml)
    classes = []
    doc.root.each_element do |el|
      next unless el.namespace == OWL_NS && el.name == 'Class'

      about = el.attributes.get_attribute_ns(RDF_NS, 'about')&.value
      next if about.nil?

      k = Klass.new(name: fragment(about), labels: [], comments: [], supers: [], props: Hash.new { |h, key| h[key] = [] })
      el.each_element do |child|
        # xml:lang by its prefix: the xml prefix is built into XML, but REXML only knows its
        # namespace if the file happens to declare xmlns:xml (this one does; a valid file
        # without that declaration would otherwise have every label reported as untagged).
        lang = (child.attributes['xml:lang'] || child.attributes.get_attribute_ns(XML_NS, 'lang')&.value).to_s.strip
        entry = { text: child.texts.map(&:value).join, lang: lang.empty? ? nil : lang }
        if child.namespace == RDFS_NS
          case child.name
          when 'label' then k.labels << entry
          when 'comment' then k.comments << entry
          when 'subClassOf'
            res = child.attributes.get_attribute_ns(RDF_NS, 'resource')&.value
            k.supers << fragment(res) if res
          end
        elsif child.namespace == LOCAL_NS
          k.props[child.name] << entry.merge(resource: child.attributes.get_attribute_ns(RDF_NS, 'resource')&.value)
        end
      end
      classes << k
    end
    classes
  end

  def self.check_classes(classes, languages:)
    findings = []

    classes.select { |k| k.supers.include?('forms') }.each do |form|
      FORM_REQUIRED.each do |prop, shown|
        next unless form.props[prop].empty?

        findings << finding(:error, :form_incomplete, form.name, "form has no #{shown} - it would never be listed in a menu")
      end
    end

    findings.concat(check_conditional_requirements(classes))

    classes.each do |k|
      k.labels.each do |l|
        findings << finding(:error, :empty_label, k.name, 'has a blank label') if l[:text].strip.empty?
        next if l[:lang]

        findings << finding(:error, :untagged_label, k.name,
                            "label #{l[:text].inspect} has no language tag (needs xml:lang=\"en\" or \"es\")")
      end

      k.comments.reject { |c| c[:lang] }.each do |c|
        findings << finding(:warning, :untagged_comment, k.name,
                            "comment #{shorten(c[:text])} has no language tag, so it is not shown to users " \
                            '(fine for an editor note; add xml:lang to make it help text)')
      end

      by_lang = k.labels.select { |l| l[:lang] }.group_by { |l| l[:lang].downcase.split('-').first }
      unless k.labels.empty?
        missing = languages - by_lang.keys
        unless missing.empty?
          has = by_lang.keys.sort.join(', ')
          findings << finding(:error, :missing_language, k.name,
                              "has no label in #{missing.join(', ')} (has: #{has.empty? ? 'untagged labels only' : has})")
        end
      end

      by_lang.each do |lang, ls|
        next unless ls.size > 1

        findings << finding(:warning, :duplicate_label, k.name,
                            "has #{ls.size} labels in '#{lang}': #{ls.map { |l| l[:text].inspect }.join(' / ')}")
      end

      if k.supers.include?('ui-text')
        names = by_lang.transform_values { |ls| ls.flat_map { |l| l[:text].scan(/%\{(\w+)\}/).flatten }.sort }
        unless names.values.uniq.size <= 1
          shown = names.map { |lang, ns| "#{lang}: #{ns.empty? ? '(none)' : ns.map { |n| "%{#{n}}" }.join(' ')}" }.join('; ')
          findings << finding(:error, :ui_text_placeholders, k.name,
                              "the %{...} names differ between languages (#{shown}) - keep them identical")
        end
        k.labels.each do |l|
          next unless l[:text] =~ /[`"<>\\]|\$\{/

          findings << finding(:error, :ui_text_characters, k.name,
                              "label #{shorten(l[:text])} contains a character that is not allowed in interface text (` \" < > \\ or ${)")
        end
      end

      TAGGED_BY_CONVENTION.each do |prop|
        k.props[prop].reject { |p| p[:lang] }.each do |p|
          findings << finding(:error, :untagged_annotation, k.name,
                              "local:#{prop} #{p[:text].inspect} has no language tag (the other forms write it with xml:lang=\"en\")")
        end
      end
    end

    findings.sort_by { |f| [f.severity == :error ? 0 : 1, f.code.to_s, f.subject.to_s] }
  end

  CONDITIONAL_PARTS = { 'conditional-requirement-field' => 'the field that becomes required',
                        'conditional-requirement-when-field' => 'the field whose answer decides',
                        'conditional-requirement-when-answer' => 'the answer(s) that make it required' }.freeze

  # A conditional requirement ("this field is required when that field has one
  # of these answers") must name all three parts, and everything it names -
  # and every rule a form lists - must exist, or the rule would silently never
  # apply.
  def self.check_conditional_requirements(classes)
    findings = []
    by_name = classes.to_h { |k| [k.name, k] }

    classes.select { |k| k.supers.include?('conditional-requirement') }.each do |rule|
      CONDITIONAL_PARTS.each do |prop, meaning|
        if rule.props[prop].empty?
          findings << finding(:error, :conditional_requirement_incomplete, rule.name, "has no local:#{prop} (#{meaning})")
        end
        rule.props[prop].each do |p|
          target = fragment(p[:resource])
          next if p[:resource] && by_name.key?(target)

          findings << finding(:error, :conditional_requirement_unknown, rule.name,
                              "local:#{prop} points at #{target.inspect}, which is not a class in the ontology")
        end
      end
    end

    classes.each do |form|
      form.props['has-conditional-requirements'].each do |p|
        target = fragment(p[:resource])
        next if p[:resource] && by_name[target]&.supers&.include?('conditional-requirement')

        findings << finding(:error, :conditional_requirement_unknown, form.name,
                            "local:has-conditional-requirements points at #{target.inspect}, which is not a conditional requirement")
      end
    end
    findings
  end

  def self.fragment(uri)
    uri.to_s.split(/[#\/]/).last
  end

  def self.finding(severity, code, subject, detail)
    Finding.new(severity: severity, code: code, subject: subject, detail: detail)
  end

  def self.shorten(text, max = 60)
    t = text.to_s.strip
    (t.length > max ? "#{t[0, max]}..." : t).inspect
  end

  # ------------------------------------------------------------------ CLI
  def self.run(argv)
    options = { languages: DEFAULT_LANGUAGES, errors_only: false }
    OptionParser.new do |o|
      o.banner = 'Usage: ruby check_ontology.rb [options] [ontology.owl]'
      o.on('--languages LIST', 'languages every labelled class needs (default en,es)') { |v| options[:languages] = v.split(',').map(&:strip) }
      o.on('--errors-only', 'do not print warnings') { options[:errors_only] = true }
    end.parse!(argv)

    path = argv[0] || File.join(__dir__, 'cbgp-application-ontology.owl')
    unless File.file?(path)
      warn "Cannot read #{path}"
      return 2
    end

    findings = check_file(path, languages: options[:languages])
    lines = line_numbers(path)
    errors = errors(findings)
    class_count = File.read(path, encoding: 'UTF-8').scan('<owl:Class rdf:about=').size

    puts "Checked #{path}"
    puts "  #{class_count} classes, #{errors.size} error(s), #{findings.size - errors.size} warning(s)"
    puts

    (options[:errors_only] ? errors : findings).group_by(&:code).each do |code, group|
      puts "#{group.first.severity.to_s.upcase}: #{code} (#{group.size})"
      group.each { |f| puts format('  %-10s %-52s %s', lines[f.subject] ? "line #{lines[f.subject]}" : 'line ?', f.subject, f.detail) }
      puts
    end

    puts errors.empty? ? 'OK - no errors.' : "FAILED - #{errors.size} error(s) to fix in the ontology."
    errors.empty? ? 0 : 1
  end
end

exit(OntologyCheck.run(ARGV)) if $PROGRAM_NAME == __FILE__
