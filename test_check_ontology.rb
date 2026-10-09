# frozen_string_literal: true

# Tests for check_ontology.rb.   Run:  ruby test_check_ontology.rb
# (standard library only - nothing to install)
require 'minitest/autorun'
require 'tmpdir'
require_relative 'check_ontology'

class TestCheckOntology < Minitest::Test
  HEAD = <<~XML
    <?xml version="1.0"?>
    <rdf:RDF xmlns="https://w3id.org/CBGP-App#" xml:base="https://w3id.org/CBGP-App"
         xmlns:owl="http://www.w3.org/2002/07/owl#" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:xml="http://www.w3.org/XML/1998/namespace" xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
         xmlns:local="urn:local:">
  XML
  TAIL = "</rdf:RDF>\n"
  APP = 'https://w3id.org/CBGP-App#'

  def klass(name, body)
    %(<owl:Class rdf:about="#{APP}#{name}">\n#{body}\n</owl:Class>\n)
  end

  def labels(en: 'X', es: 'X')
    out = +''
    out << %(<rdfs:label xml:lang="en">#{en}</rdfs:label>\n) if en
    out << %(<rdfs:label xml:lang="es">#{es}</rdfs:label>\n) if es
    out
  end

  def check(*classes, **opts)
    OntologyCheck.check_xml(HEAD + classes.join + TAIL, **opts)
  end

  def codes(findings) = findings.map(&:code)

  # ---- untagged labels
  def test_flags_an_untagged_label_naming_the_class
    f = check(klass('broken', labels + "<rdfs:label>Oops</rdfs:label>")).find { |x| x.code == :untagged_label }
    refute_nil f
    assert_equal :error, f.severity
    assert_equal 'broken', f.subject
    assert_includes f.detail, '"Oops"'
  end

  def test_quiet_when_everything_is_tagged
    assert_empty check(klass('ok', labels))
  end

  def test_empty_xml_lang_counts_as_untagged
    assert_includes codes(check(klass('c', labels + '<rdfs:label xml:lang="">x</rdfs:label>'))), :untagged_label
  end

  def test_flags_a_blank_label
    assert_includes codes(check(klass('blank', labels(es: ' ')))), :empty_label
  end

  # ---- language consistency
  def test_flags_english_without_spanish
    f = check(klass('englishonly', labels(es: nil))).find { |x| x.code == :missing_language }
    assert_equal :error, f.severity
    assert_includes f.detail, 'no label in es'
  end

  def test_flags_spanish_without_english
    f = check(klass('spanishonly', labels(en: nil))).find { |x| x.code == :missing_language }
    assert_includes f.detail, 'no label in en'
  end

  def test_a_class_whose_only_label_is_untagged_is_missing_both
    f = check(klass('untaggedonly', '<rdfs:label>Plain</rdfs:label>')).find { |x| x.code == :missing_language }
    assert_includes f.detail, 'en, es'
    assert_includes f.detail, 'untagged labels only'
  end

  def test_a_class_with_no_labels_at_all_is_left_alone
    assert_empty check(klass('bare', ''))
  end

  def test_regional_variants_count
    assert_empty check(klass('regional', '<rdfs:label xml:lang="en">A</rdfs:label><rdfs:label xml:lang="es-ES">B</rdfs:label>'))
  end

  def test_more_languages_can_be_required
    assert_includes codes(check(klass('two', labels), languages: %w[en es fr])), :missing_language
  end

  def test_duplicate_labels_in_one_language_warn
    f = check(klass('dup', labels + '<rdfs:label xml:lang="en">Second</rdfs:label>')).find { |x| x.code == :duplicate_label }
    assert_equal :warning, f.severity
  end

  # ---- comments
  def test_untagged_comment_is_only_a_warning
    findings = check(klass('noted', labels + '<rdfs:comment>(Deprecated)</rdfs:comment>'))
    assert_equal :warning, findings.find { |x| x.code == :untagged_comment }.severity
    assert_empty OntologyCheck.errors(findings)
  end

  def test_tagged_comment_is_fine
    assert_empty check(klass('noted', labels + '<rdfs:comment xml:lang="en">Help</rdfs:comment>'))
  end

  # ---- the original bug
  def described(en: 'What it is.', es: 'Qué es.')
    %(<rdfs:comment xml:lang="en">#{en}</rdfs:comment>\n<rdfs:comment xml:lang="es">#{es}</rdfs:comment>\n)
  end

  def form(name, category:, description: described)
    klass(name, labels + description + <<~XML)
      <rdfs:subClassOf rdf:resource="#{APP}forms"/>
      <local:dbname xml:lang="en">project</local:dbname>
      #{category}
      <local:has-fields rdf:resource="#{APP}fields-x"/>
    XML
  end

  def test_form_category_without_a_language_tag_is_an_error_naming_the_form
    f = check(form('european', category: '<local:form-category>Core</local:form-category>')).find { |x| x.code == :untagged_annotation }
    assert_equal :error, f.severity
    assert_equal 'european', f.subject
    assert_includes f.detail, 'form-category'
  end

  def test_tagged_form_is_fine
    assert_empty check(form('national', category: '<local:form-category xml:lang="en">Core</local:form-category>'))
  end

  # ---- form descriptions (read by the AI agent interface)
  def test_form_without_any_description_warns_once_per_language
    found = check(form('bare', category: '<local:form-category xml:lang="en">Core</local:form-category>', description: ''))
            .select { |x| x.code == :form_without_description }
    assert_equal 2, found.size
    assert(found.all? { |f| f.severity == :warning && f.subject == 'bare' })
    assert_match(/in en/, found.map(&:detail).join)
    assert_match(/in es/, found.map(&:detail).join)
  end

  def test_form_described_in_only_one_language_warns_for_the_other
    found = check(form('half', category: '<local:form-category xml:lang="en">Core</local:form-category>',
                               description: described(es: '').sub(%(<rdfs:comment xml:lang="es"></rdfs:comment>\n), '')))
            .select { |x| x.code == :form_without_description }
    assert_equal 1, found.size
    assert_match(/in es/, found.first.detail)
  end

  def test_a_blank_or_untagged_comment_is_not_a_description
    found = check(form('hollow', category: '<local:form-category xml:lang="en">Core</local:form-category>',
                                 description: '<rdfs:comment xml:lang="en"> </rdfs:comment><rdfs:comment>Untagged</rdfs:comment>'))
            .select { |x| x.code == :form_without_description }
    assert_equal 2, found.size
  end

  def test_a_fully_described_form_is_fine
    assert_empty check(form('good', category: '<local:form-category xml:lang="en">Core</local:form-category>'))
  end

  def test_the_forms_root_class_wants_a_description_too
    found = check(klass('forms', labels)).select { |x| x.code == :form_without_description }
    assert_equal 2, found.size
    assert_match(/dataset as a whole/, found.first.detail)
    assert_empty check(klass('forms', labels + described))
  end

  def test_other_classes_do_not_need_a_description
    assert_empty check(klass('field', labels))
  end

  def test_the_real_ontology_describes_every_form
    path = File.join(__dir__, 'cbgp-application-ontology.owl')
    missing = OntologyCheck.check_file(path).select { |f| f.code == :form_without_description }
    assert_empty missing, "forms without a description:\n" + missing.map { |f| "  #{f}" }.join("\n")
  end

  def test_form_missing_category_dbname_and_fields
    problems = check(klass('orphan', labels + %(<rdfs:subClassOf rdf:resource="#{APP}forms"/>))).select { |x| x.code == :form_incomplete }
    assert_equal 3, problems.size
    assert_match(/form-category/, problems.map(&:detail).join)
    assert_match(/dbname/, problems.map(&:detail).join)
    assert_match(/has-fields/, problems.map(&:detail).join)
  end

  def test_does_not_depend_on_the_file_declaring_xmlns_xml
    xml = %(<rdf:RDF xmlns:owl="http://www.w3.org/2002/07/owl#" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#">\n) +
          klass('nodecl', labels) + TAIL
    assert_empty OntologyCheck.check_xml(xml)
  end

  # ---- ordering, line numbers, robustness
  def test_errors_come_before_warnings
    sev = check(klass('a', labels(es: nil)), klass('b', labels + '<rdfs:label xml:lang="en">Again</rdfs:label>')).map(&:severity)
    assert_equal sev, sev.sort_by { |s| s == :error ? 0 : 1 }
  end

  # ---- interface texts (subclasses of cbgp:ui-text)
  def ui_text(name, en:, es:)
    klass(name, %(<rdfs:subClassOf rdf:resource="#{APP}ui-text"/>\n) + labels(en: en, es: es))
  end

  def test_interface_text_with_matching_placeholders_is_fine
    assert_empty check(ui_text('ui_hint', en: 'Search %{target}...', es: 'Buscar en %{target}...'))
  end

  def test_interface_text_whose_placeholders_differ_between_languages_is_an_error
    f = check(ui_text('ui_hint', en: 'Search %{target}...', es: 'Buscar en %{objetivo}...')).find { |x| x.code == :ui_text_placeholders }
    refute_nil f
    assert_equal :error, f.severity
    assert_equal 'ui_hint', f.subject
    assert_includes f.detail, '%{target}'
    assert_includes f.detail, '%{objetivo}'
  end

  def test_interface_text_missing_a_placeholder_in_one_language_is_an_error
    assert_includes codes(check(ui_text('ui_hint', en: 'Search %{target}', es: 'Buscar'))), :ui_text_placeholders
  end

  def test_interface_text_with_characters_that_break_the_page_is_an_error
    ['say "hi"', 'a &lt;b&gt;', 'back`tick', 'cost ${x}', 'a \\ b'].each do |bad|
      assert_includes codes(check(ui_text('ui_hint', en: bad, es: 'ok'))), :ui_text_characters, bad
    end
  end

  def test_placeholders_are_not_checked_on_ordinary_classes
    refute_includes codes(check(klass('plain', labels(en: 'A %{x}', es: 'B')))), :ui_text_placeholders
  end

  def test_finds_the_line_a_class_is_declared_on
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'o.owl')
      File.write(path, %(<rdf:RDF>\n\n<owl:Class rdf:about="#{APP}first">\n</owl:Class>\n<owl:Class rdf:about="#{APP}second">\n</rdf:RDF>))
      assert_equal({ 'first' => 3, 'second' => 5 }, OntologyCheck.line_numbers(path))
    end
  end

  def test_unreadable_file_gives_no_line_numbers
    assert_equal({}, OntologyCheck.line_numbers('/no/such/file.owl'))
  end

  def test_labels_with_xml_entities_and_non_ascii
    assert_empty check(klass('ent', labels(en: 'Funding &amp; Tenders', es: 'Financiación &lt;y&gt; licitaciones – ñ 日本')))
  end

  # ---- conditional requirements
  def rule(name, field: 'f', when_field: 'w', answers: ['a'], extra: '')
    parts = +%(<rdfs:subClassOf rdf:resource="#{APP}conditional-requirement"/>\n)
    parts << %(<local:conditional-requirement-field rdf:resource="#{APP}#{field}"/>\n) if field
    parts << %(<local:conditional-requirement-when-field rdf:resource="#{APP}#{when_field}"/>\n) if when_field
    answers.each { |a| parts << %(<local:conditional-requirement-when-answer rdf:resource="#{APP}#{a}"/>\n) }
    klass(name, labels + parts + extra)
  end

  def simple_classes = %w[f w a].map { |n| klass(n, labels) }

  def test_a_complete_conditional_requirement_is_fine
    assert_empty check(klass('conditional-requirement', labels), rule('r1'), *simple_classes)
  end

  def test_flags_a_conditional_requirement_missing_a_part
    f = check(klass('conditional-requirement', labels), rule('r1', answers: []), *simple_classes)
    assert_includes codes(f), :conditional_requirement_incomplete
    assert_equal 'r1', f.find { |x| x.code == :conditional_requirement_incomplete }.subject
    assert_includes codes(check(klass('conditional-requirement', labels), rule('r2', field: nil), *simple_classes)), :conditional_requirement_incomplete
  end

  def test_flags_a_conditional_requirement_pointing_at_a_missing_class
    f = check(klass('conditional-requirement', labels), rule('r1', answers: ['Awardd']), *simple_classes)
    assert_includes codes(f), :conditional_requirement_unknown
    assert_includes f.find { |x| x.code == :conditional_requirement_unknown }.detail, 'Awardd'
  end

  def test_flags_a_form_listing_a_rule_that_does_not_exist
    form = klass('some_form', labels + %(<local:has-conditional-requirements rdf:resource="#{APP}nope"/>))
    assert_includes codes(check(form)), :conditional_requirement_unknown
  end

  def test_a_form_listing_a_real_rule_is_fine
    form = klass('some_form', labels + %(<local:has-conditional-requirements rdf:resource="#{APP}r1"/>))
    assert_empty check(klass('conditional-requirement', labels), rule('r1'), form, *simple_classes)
  end

  # ---- label companions
  def companion(name, to)
    klass(name, labels + %(<local:label-companion rdf:resource="#{APP}#{to}"/>))
  end

  def test_a_label_companion_pointing_at_a_real_class_is_fine
    assert_empty check(companion('surnames', 'given_name'), klass('given_name', labels))
  end

  def test_flags_a_label_companion_pointing_at_a_missing_class
    f = check(companion('surnames', 'giv_name'), klass('given_name', labels)).find { |x| x.code == :label_companion_unknown }
    refute_nil f
    assert_equal 'surnames', f.subject
    assert_includes f.detail, 'giv_name'
  end

  def test_flags_a_label_companion_pointing_at_the_field_itself
    f = check(companion('surnames', 'surnames')).find { |x| x.code == :label_companion_unknown }
    refute_nil f
    assert_includes f.detail, 'itself'
  end

  # ---- primary ids must hold one value
  def primary(name, flag: 'true', cardinality: 'Single')
    body = labels + %(<local:is-primary-id rdf:datatype="http://www.w3.org/2001/XMLSchema#boolean">#{flag}</local:is-primary-id>\n)
    body << %(<local:widget-cardinality>#{cardinality}</local:widget-cardinality>\n) if cardinality
    klass(name, body)
  end

  def test_a_single_valued_primary_id_is_fine
    assert_empty check(primary('dni'))
  end

  def test_flags_a_repeatable_primary_id
    f = check(primary('project_internal_code', cardinality: 'Multiple')).find { |x| x.code == :primary_id_repeatable }
    refute_nil f
    assert_equal :error, f.severity
    assert_equal 'project_internal_code', f.subject
    assert_includes f.detail, 'Single'
  end

  def test_a_repeatable_field_that_is_not_a_primary_id_is_fine
    assert_empty check(primary('keywords', flag: 'false', cardinality: 'Multiple'))
    assert_empty check(klass('notes', labels + '<local:widget-cardinality>Multiple</local:widget-cardinality>'))
  end

  def test_a_primary_id_with_no_stated_cardinality_is_not_flagged
    assert_empty check(primary('dni', cardinality: nil))
  end

  # ---- the real file
  def test_the_real_ontology_has_no_errors
    path = File.join(__dir__, 'cbgp-application-ontology.owl')
    errors = OntologyCheck.errors(OntologyCheck.check_file(path))
    lines = OntologyCheck.line_numbers(path)
    assert_empty errors, "ontology has #{errors.size} error(s):\n" + errors.first(20).map { |f| "  line #{lines[f.subject]}: #{f}" }.join("\n")
  end

  def test_command_line_exit_codes
    Dir.mktmpdir do |dir|
      good = File.join(dir, 'good.owl')
      bad = File.join(dir, 'bad.owl')
      File.write(good, HEAD + klass('ok', labels) + TAIL)
      File.write(bad, HEAD + klass('bad', labels(es: nil)) + TAIL)
      script = File.join(__dir__, 'check_ontology.rb')
      assert system(RbConfig.ruby, script, good, out: File::NULL, err: File::NULL)
      refute system(RbConfig.ruby, script, bad, out: File::NULL, err: File::NULL)
      assert_equal 2, (system(RbConfig.ruby, script, File.join(dir, 'missing.owl'), out: File::NULL, err: File::NULL) ? 0 : $?.exitstatus)
    end
  end
end
