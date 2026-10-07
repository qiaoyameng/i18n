require 'test_helper'

class I18nBackendBlockedTest < I18n::TestCase
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
    store_translations(:en,
      :active   => 'Active copy',
      :retired  => I18n::BLOCKED,
      :falsy    => false,
      :empty    => '',
      :nothing  => nil,
      :section  => { :keep => 'Kept', :retired => I18n::BLOCKED },
      :removed  => I18n::BLOCKED,
      :plural   => { :one => I18n::BLOCKED, :other => '%{count} items' },
      :items    => ['First', I18n::BLOCKED],
      :retired_alias => :retired)
  end

  test "the sentinel is a distinct frozen object" do
    assert I18n::BLOCKED.frozen?
    assert_equal false, I18n::BLOCKED == nil
    assert_equal false, I18n::BLOCKED == false
    assert_equal false, I18n::BLOCKED == ''
    assert_equal 'I18n::BLOCKED', I18n::BLOCKED.inspect
  end

  test "translate: a blocked leaf is reported as missing" do
    assert_equal 'Translation blocked: en.retired', I18n.t(:retired)
  end

  test "translate: a blocked leaf raises BlockedTranslationData with raise" do
    assert_raises(I18n::BlockedTranslationData) { I18n.t(:retired, :raise => true) }
  end

  test "translate: a blocked leaf throws a BlockedTranslation" do
    exception = catch(:exception) { I18n.t(:retired, :throw => true) }
    assert_kind_of I18n::BlockedTranslation, exception
    assert_kind_of I18n::MissingTranslation, exception
  end

  test "exists?: a blocked leaf does not exist" do
    assert_equal false, I18n.exists?(:retired)
  end

  test "exists?: siblings are unaffected by a blocked leaf" do
    assert_equal true, I18n.exists?(:active)
  end

  test "nil, false and the empty string keep their original semantics" do
    assert_nil I18n.t(:nothing, :default => nil)
    assert_equal false, I18n.t(:falsy)
    assert_equal '', I18n.t(:empty)
    assert_equal true, I18n.exists?(:falsy)
    assert_equal true, I18n.exists?(:empty)
  end

  test "namespace: a blocked leaf inside a subtree is missing" do
    assert_equal 'Translation blocked: en.section.retired', I18n.t(:'section.retired')
    assert_equal false, I18n.exists?(:'section.retired')
  end

  test "namespace: other leaves in the same subtree still resolve" do
    assert_equal 'Kept', I18n.t(:'section.keep')
  end

  test "namespace: the marker never appears in a returned subtree" do
    assert_equal({ :keep => 'Kept' }, I18n.t(:section))
  end

  test "namespace: a blocked marker inside an array turns into nil" do
    assert_equal ['First', nil], I18n.t(:items)
  end

  test "namespace: blocking an entire namespace blocks every descendant" do
    assert_equal 'Translation blocked: en.removed', I18n.t(:removed)
    assert_equal 'Translation blocked: en.removed.anything.deep', I18n.t(:'removed.anything.deep')
    assert_equal false, I18n.exists?(:removed)
    assert_equal false, I18n.exists?(:'removed.anything.deep')
  end

  test "an explicit non-Symbol default is still used for a blocked key" do
    assert_equal 'Replacement', I18n.t(:retired, :default => 'Replacement')
    assert_equal false, I18n.t(:retired, :default => false)
    assert_equal({ :zero => 'Zero' }, I18n.t(:retired, :default => { :zero => 'Zero' }))
    assert_equal 'Called', I18n.t(:retired, :default => Proc.new { 'Called' })
    assert_equal 'Replacement %{name}', I18n.t(:retired, :default => 'Replacement %{name}', :name => 'X', :skip_interpolation => true)
  end

  test "an explicit nil default returns nil for a blocked key" do
    assert_nil I18n.t(:retired, :default => nil)
  end

  test "a Symbol default that points at a blocked key stays blocked" do
    assert_equal 'Translation blocked: en.retired', I18n.t(:other, :default => :retired)
  end

  test "mixed defaults skip blocked Symbols and use the first non-Symbol value" do
    assert_equal 'Replacement', I18n.t(:other, :default => [:retired, 'Replacement'])
    assert_equal false, I18n.t(:other, :default => [:retired, false])
  end

  test "an alias stored as a Symbol can point at a blocked key" do
    assert_equal 'Translation blocked: en.retired_alias', I18n.t(:retired_alias)
    assert_equal false, I18n.exists?(:retired_alias)
  end

  test "a blocked pluralization form is reported blocked" do
    assert_raises(I18n::BlockedTranslationData) { I18n.t(:plural, :count => 1, :raise => true) }
    assert_equal '2 items', I18n.t(:plural, :count => 2)
  end

  test "removing the block restores ordinary missing-key behavior" do
    translations[:en].delete(:retired)
    assert_equal 'Translation missing: en.retired', I18n.t(:retired)
    assert_equal false, I18n.exists?(:retired)
  end
end

class I18nBackendChainBlockedTest < I18n::TestCase
  def setup
    super
    @top = I18n::Backend::Simple.new
    @bottom = I18n::Backend::Simple.new
    @top.store_translations(:en,
      :shared   => I18n::BLOCKED,
      :top_only => 'Top',
      :section  => { :old => I18n::BLOCKED, :top_key => 'Top key' },
      :namespace_block => I18n::BLOCKED,
      :alias_to_blocked => :shared)
    @bottom.store_translations(:en,
      :shared   => 'Bottom copy',
      :bottom_only => 'Bottom',
      :section  => { :old => 'Bottom old', :bottom_key => 'Bottom key' },
      :namespace_block => { :child => 'Bottom child' })
    I18n.backend = I18n::Backend::Chain.new(@top, @bottom)
  end

  test "a block in an earlier backend hides lower backend translations" do
    assert_equal 'Translation blocked: en.shared', I18n.t(:shared)
    assert_equal false, I18n.exists?(:shared)
  end

  test "non blocked keys still resolve from each backend" do
    assert_equal 'Top', I18n.t(:top_only)
    assert_equal 'Bottom', I18n.t(:bottom_only)
  end

  test "namespace merges drop blocked leaves contributed by earlier backends" do
    assert_equal({ :top_key => 'Top key', :bottom_key => 'Bottom key' }, I18n.t(:section))
    assert_equal 'Translation blocked: en.section.old', I18n.t(:'section.old')
    assert_equal false, I18n.exists?(:'section.old')
  end

  test "a blocked namespace masks the matching lower backend subtree" do
    assert_equal 'Translation blocked: en.namespace_block.child', I18n.t(:'namespace_block.child')
    assert_equal false, I18n.exists?(:'namespace_block.child')
  end

  test "an explicit non-Symbol default still applies on the chain" do
    assert_equal 'Default', I18n.t(:shared, :default => 'Default')
    assert_nil I18n.t(:shared, :default => nil)
  end

  test "an alias in the chain resolving to a blocked entry is blocked" do
    assert_equal 'Translation blocked: en.alias_to_blocked', I18n.t(:alias_to_blocked)
  end

  test "removing the block restores the lower backend translation" do
    @top.send(:translations)[:en].delete(:shared)
    assert_equal 'Bottom copy', I18n.t(:shared)
    assert_equal true, I18n.exists?(:shared)
  end
end

class I18nBackendFallbacksBlockedTest < I18n::TestCase
  class Backend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    I18n.backend = Backend.new
    I18n.fallbacks.map(:'de-DE' => :en)
    store_translations(:en,
      :english_only => 'English',
      :retired      => I18n::BLOCKED,
      :section      => { :old => I18n::BLOCKED, :fresh => 'English fresh' })
    store_translations(:'de-DE', :local => 'German')
  end

  test "normal fallback translations are unaffected" do
    assert_equal 'English', I18n.t(:english_only, :locale => :'de-DE')
    assert_equal 'German', I18n.t(:local, :locale => :'de-DE')
  end

  test "a block in a fallback locale stops further fallback lookups" do
    assert_equal 'Translation blocked: de-DE.retired', I18n.t(:retired, :locale => :'de-DE')
    assert_equal false, I18n.exists?(:retired, :locale => :'de-DE')
  end

  test "a blocked subtree in a fallback locale blocks its descendants" do
    assert_equal 'Translation blocked: de-DE.section.old', I18n.t(:'section.old', :locale => :'de-DE')
    assert_equal false, I18n.exists?(:'section.old', :locale => :'de-DE')
    assert_equal 'English fresh', I18n.t(:'section.fresh', :locale => :'de-DE')
  end

  test "an explicit non-Symbol default still applies" do
    assert_equal 'Default', I18n.t(:retired, :locale => :'de-DE', :default => 'Default')
    assert_nil I18n.t(:retired, :locale => :'de-DE', :default => nil)
  end

  test "disabling fallback does not make a block leak a value" do
    assert_equal 'Translation blocked: en.retired', I18n.t(:retired, :locale => :en, :fallback => false)
  end
end

class I18nBackendChainWithFallbacksBlockedTest < I18n::TestCase
  class Backend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    @top = Backend.new
    @bottom = Backend.new
    I18n.backend = I18n::Backend::Chain.new(@top, @bottom)
    I18n.fallbacks.map(:'de-DE' => :en)
    @top.store_translations(:en, :shared => I18n::BLOCKED, :section => { :old => I18n::BLOCKED })
    @bottom.store_translations(:en, :shared => 'English bottom')
    @bottom.store_translations(:'de-DE', :shared => 'German bottom')
  end

  test "a block in an earlier backend masks lower backends and fallback locales" do
    assert_equal 'Translation blocked: de-DE.shared', I18n.t(:shared, :locale => :'de-DE')
    assert_equal false, I18n.exists?(:shared, :locale => :'de-DE')
  end

  test "blocked subtree leaves are masked through the chain and fallbacks" do
    assert_equal 'Translation blocked: de-DE.section.old', I18n.t(:'section.old', :locale => :'de-DE')
    assert_equal false, I18n.exists?(:'section.old', :locale => :'de-DE')
  end

  test "explicit defaults still work in the combined setup" do
    assert_equal 'Default', I18n.t(:shared, :locale => :'de-DE', :default => 'Default')
    assert_nil I18n.t(:shared, :locale => :'de-DE', :default => nil)
  end

  test "removing the block restores fallback translations from lower backends" do
    @top.send(:translations)[:en].delete(:shared)
    assert_equal 'German bottom', I18n.t(:shared, :locale => :'de-DE')
    assert_equal true, I18n.exists?(:shared, :locale => :'de-DE')
  end
end

class I18nBackendPluralizationBlockedTest < I18n::TestCase
  class Backend < I18n::Backend::Simple
    include I18n::Backend::Pluralization
  end

  def setup
    super
    I18n.backend = Backend.new
    rule = lambda { |n| n == 1 ? :one : :other }
    store_translations(:xx, :i18n => { :plural => { :rule => rule } })
  end

  test "a blocked pluralization category is reported blocked rather than raising invalid data" do
    store_translations(:xx, :mail => { :one => I18n::BLOCKED, :other => '%{count} mails' })
    assert_raises(I18n::BlockedTranslationData) { I18n.t(:mail, :count => 1, :locale => :xx, :raise => true) }
    assert_equal '2 mails', I18n.t(:mail, :count => 2, :locale => :xx)
  end

  test "a blocked explicit count form is reported blocked" do
    store_translations(:xx, :mail => { :"1" => I18n::BLOCKED, :one => 'one', :other => '%{count} mails' })
    assert_raises(I18n::BlockedTranslationData) { I18n.t(:mail, :count => 1, :locale => :xx, :raise => true) }
  end
end
