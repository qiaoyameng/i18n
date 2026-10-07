require 'test_helper'

class I18nTraceTest < I18n::TestCase
  class FallbackBackend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
    store_translations(:en,
      :foo          => 'Foo',
      :greeting     => 'Hello %{name}',
      :alias        => :aliased,
      :aliased      => 'Aliased',
      :false_value  => false,
      :plural       => { :one => 'one %{what}', :other => '%{count} %{what}' },
      :bad_plural   => { :one => 'one' }
    )
    store_translations(:de, :foo => 'Foo de')
  end

  def events(node)
    node.events.map(&:to_h)
  end

  test "returns the normal translation when tracing" do
    assert_equal 'Foo', I18n.t(:foo, :trace => true)
    assert_equal 'Hello Smith', I18n.t(:greeting, :name => 'Smith', :trace => true)
  end

  test "records backend, locale, key and outcome of the lookup" do
    I18n.t(:foo, :trace => true)
    node = I18n.last_trace.root
    assert_equal I18n.backend, node.backend
    assert_equal :en, node.locale
    assert_equal :foo, node.key
    assert node.hit?
    assert node.finished?
    assert_equal 'Foo', node.entry
  end

  test "exposes the trace through a passed I18n::Trace instance" do
    trace = I18n::Trace.new
    assert_equal 'Foo', I18n.t(:foo, :trace => trace)
    assert_equal :foo, trace.root.key
    assert_same trace, I18n.last_trace
  end

  test "records the final hit location" do
    I18n.t(:foo, :trace => true)
    hit = I18n.last_trace.final_hit
    assert_equal I18n.backend, hit.backend
    assert_equal :en, hit.locale
    assert_equal :foo, hit.key
  end

  test "does not record interpolation values by default" do
    I18n.t(:greeting, :name => 'Smith', :trace => true)
    node = I18n.last_trace.root
    assert_equal 'Hello %{name}', node.entry
    assert_equal [{ :type => :interpolate, :keys => [:name] }], events(node)
    assert_nil node.result
    refute node.to_h.inspect.include?('Smith')
  end

  test "records interpolation values and result when include_values is set" do
    trace = I18n::Trace.new(:include_values => true)
    I18n.t(:greeting, :name => 'Smith', :trace => trace)
    node = trace.root
    assert_equal 'Hello Smith', node.result
    assert_equal [{ :type => :interpolate, :keys => [:name], :values => { :name => 'Smith' } }], events(node)
  end

  test "records symbol alias jumps as parent/child nodes" do
    assert_equal 'Aliased', I18n.t(:alias, :trace => true)
    root = I18n.last_trace.root
    assert_equal :alias, root.key
    assert root.hit?
    assert_equal [{ :type => :alias, :from => :alias, :to => :aliased }], events(root)
    assert_equal 1, root.children.size
    child = root.children.first
    assert_equal :aliased, child.key
    assert child.hit?
    assert_equal child, I18n.last_trace.final_hit
  end

  test "records missing translations with a complete end record" do
    I18n.t(:missing, :trace => true)
    node = I18n.last_trace.root
    assert node.missing?
    assert node.finished?
    assert_equal 'I18n::MissingTranslation', node.error[:class]
  end

  test "records missing translations when raise: true is used" do
    assert_raises(I18n::MissingTranslationData) { I18n.t(:missing, :raise => true, :trace => true) }
    assert I18n.last_trace.root.missing?
  end

  test "records exceptions with a complete end record" do
    assert_raises(I18n::InvalidPluralizationData) { I18n.t(:bad_plural, :count => 2, :trace => true) }
    node = I18n.last_trace.root
    assert node.error?
    assert node.finished?
    assert_equal 'I18n::InvalidPluralizationData', node.error[:class]
  end

  test "records false translations as hits" do
    assert_equal false, I18n.t(:false_value, :trace => true)
    node = I18n.last_trace.root
    assert node.hit?
    assert_equal false, node.entry
  end

  test "records default usage" do
    assert_equal 'Default', I18n.t(:missing, :default => 'Default', :trace => true)
    assert_equal [{ :type => :default, :default => 'Default' }], events(I18n.last_trace.root)
  end

  test "records symbol defaults with a nested child node" do
    assert_equal 'Foo', I18n.t(:missing, :default => :foo, :trace => true)
    root = I18n.last_trace.root
    assert_equal [{ :type => :default, :default => :foo }, { :type => :alias, :from => :missing, :to => :foo }], events(root)
    assert_equal :foo, root.children.first.key
  end

  test "records proc defaults without re-executing the proc" do
    calls = 0
    default = lambda { |key, **options| calls += 1; 'From proc' }
    assert_equal 'From proc', I18n.t(:missing, :default => default, :trace => true)
    assert_equal 1, calls
    trace = I18n.last_trace
    assert_equal :default, trace.root.events.first.type
    assert_equal :proc, trace.root.events[1].type
    trace.to_h
    trace.to_s
    trace.nodes
    assert_equal 1, calls
  end

  test "records the selected pluralization branch without the count value" do
    assert_equal '2 things', I18n.t(:plural, :count => 2, :what => 'things', :trace => true)
    node = I18n.last_trace.root
    assert_equal [
      { :type => :pluralize, :key => :other },
      { :type => :interpolate, :keys => [:count, :what] }
    ], events(node)
  end

  test "records symbol alias, proc default and pluralization in a single call" do
    store_translations(:en, :combined => { :one => 'one thing', :other => '%{count} things' })
    store_translations(:en, :combined_alias => :combined)
    default = lambda { |key, **options| :combined_alias }
    assert_equal '3 things', I18n.t(:missing, :default => default, :count => 3, :trace => true)
    trace = I18n.last_trace
    types = trace.nodes.flat_map { |node| node.events.map(&:type) }
    assert_includes types, :default
    assert_includes types, :proc
    assert_includes types, :alias
    assert_includes types, :pluralize
    assert_equal :combined, trace.final_hit.key
  end

  test "records bulk lookups as separate roots" do
    I18n.t([:foo, :missing], :trace => true)
    assert_equal [:foo, :missing], I18n.last_trace.roots.map(&:key)
  end

  test "does not trace calls made without the trace option" do
    I18n.t(:foo)
    assert_nil I18n::Trace.current
  end

  test "traces are isolated between concurrent threads" do
    store_translations(:en, :other => 'Other')
    traces = {}
    threads = [:foo, :other].map do |key|
      Thread.new do
        I18n.t(key, :trace => true)
        sleep 0.01 # let the other thread run while this trace would still be "active"
        traces[key] = I18n.last_trace
      end
    end
    threads.each(&:join)
    assert_equal :foo, traces[:foo].root.key
    assert_equal :other, traces[:other].root.key
    assert_equal 1, traces[:foo].roots.size
    assert_equal 1, traces[:"other"].roots.size
  end

  test "untraced calls in other threads do not interfere" do
    I18n.t(:foo, :trace => true)
    traced = I18n.last_trace
    Thread.new { I18n.t(:other); assert_nil I18n::Trace.current; assert_nil I18n.last_trace }.join
    assert_same traced, I18n.last_trace
  end

  test "to_h and to_s describe the trace" do
    I18n.t(:alias, :trace => true)
    hash = I18n.last_trace.to_h
    assert_equal :alias, hash[:roots].first[:key]
    assert_equal :aliased, hash[:roots].first[:children].first[:key]
    assert_match(/key=:alias/, I18n.last_trace.to_s)
  end
end

class I18nTraceChainTest < I18n::TestCase
  def setup
    super
    @first  = I18n::Backend::Simple.new
    @first.store_translations(:en, :foo => 'Foo', :false_value => false, :nil_value => nil)
    @second = I18n::Backend::Simple.new
    @second.store_translations(:en, :bar => 'Bar', :nil_value => 'Not nil')
    I18n.backend = I18n::Backend::Chain.new(@first, @second)
  end

  test "records each backend tried in chain priority order" do
    assert_equal 'Bar', I18n.t(:bar, :trace => true)
    root = I18n.last_trace.root
    assert_equal I18n::Backend::Chain, root.backend.class
    assert root.hit?
    assert_equal [@first, @second], root.children.map(&:backend)
    assert_equal [:missing, :hit], root.children.map(&:outcome)
    assert_equal @second, I18n.last_trace.final_hit.backend
  end

  test "keeps chain priority for the first backend" do
    assert_equal 'Foo', I18n.t(:foo, :trace => true)
    root = I18n.last_trace.root
    assert_equal 1, root.children.size
    assert_equal @first, root.children.first.backend
  end

  test "false translations stop the chain as before" do
    assert_equal false, I18n.t(:false_value, :trace => true)
    root = I18n.last_trace.root
    assert root.hit?
    assert_equal [:hit], root.children.map(&:outcome)
  end

  test "nil translations continue the chain as before" do
    assert_equal 'Not nil', I18n.t(:nil_value, :trace => true)
    root = I18n.last_trace.root
    assert_equal [:missing, :hit], root.children.map(&:outcome)
  end

  test "defaults only apply to the last backend and are recorded there" do
    assert_equal 'Bah', I18n.t(:missing, :default => 'Bah', :trace => true)
    root = I18n.last_trace.root
    assert_equal [], root.children.first.events
    assert_equal [{ :type => :default, :default => 'Bah' }], root.children.last.events.map(&:to_h)
  end

  test "records a missing chain lookup" do
    I18n.t(:missing, :trace => true)
    root = I18n.last_trace.root
    assert root.missing?
    assert root.children.all?(&:missing?)
  end
end

class I18nTraceFallbacksTest < I18n::TestCase
  def setup
    super
    I18n.backend = I18nTraceTest::FallbackBackend.new
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:de => [:en])
    store_translations(:en, :foo => 'Foo en')
    store_translations(:de, :bar => 'Bar de')
  end

  test "records each fallback locale tried" do
    assert_equal 'Foo en', I18n.t(:foo, :locale => :de, :trace => true)
    root = I18n.last_trace.root
    assert_equal :de, root.locale
    assert root.hit?
    assert_equal [:de, :en], root.children.map(&:locale)
    assert_equal [:missing, :hit], root.children.map(&:outcome)
    assert_equal [{ :type => :fallback, :from => :de, :to => :en }], root.events.map(&:to_h)
    assert_equal :en, I18n.last_trace.final_hit.locale
  end

  test "records a complete end record with fallback: false" do
    assert_equal 'Default', I18n.t(:foo, :locale => :de, :fallback => false, :default => 'Default', :trace => true)
    root = I18n.last_trace.root
    assert root.finished?
    assert root.hit?
    assert_equal [:de], root.children.map(&:locale)
    assert_equal [], root.events.select { |event| event.type == :fallback }
  end

  test "records missing translations across all fallback locales" do
    I18n.t(:missing, :locale => :de, :trace => true)
    root = I18n.last_trace.root
    assert root.missing?
    assert root.finished?
    assert_equal [:de, :en], root.children.map(&:locale)
    assert root.children.all?(&:missing?)
  end
end
