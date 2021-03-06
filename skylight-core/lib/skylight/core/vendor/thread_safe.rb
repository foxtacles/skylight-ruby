require 'thread'

module ThreadSafe
  autoload :NonConcurrentCacheBackend, 'skylight/core/vendor/thread_safe/non_concurrent_cache_backend'
  autoload :SynchronizedCacheBackend,  'skylight/core/vendor/thread_safe/synchronized_cache_backend'

  ConcurrentCacheBackend = SynchronizedCacheBackend

  class Cache < ConcurrentCacheBackend
    KEY_ERROR = defined?(KeyError) ? KeyError : IndexError # there is no KeyError in 1.8 mode

    def initialize(options = nil, &block)
      if options.kind_of?(::Hash)
        validate_options_hash!(options)
      else
        options = nil
      end

      super(options)
      @default_proc = block
    end

    def [](key)
      if value = super
        value
      elsif @default_proc && !key?(key)
        @default_proc.call(self, key)
      else
        value
      end
    end

    def fetch(key, default_value = NULL)
      if NULL != (value = get_or_default(key, NULL))
        value
      elsif block_given?
        yield key
      elsif NULL != default_value
        default_value
      else
        raise KEY_ERROR, 'key not found'
      end
    end

    def put_if_absent(key, value)
      computed = false
      result = compute_if_absent(key) do
        computed = true
        value
      end
      computed ? nil : result
    end unless method_defined?(:put_if_absent)

    def value?(value)
      each_value do |v|
        return true if value.equal?(v)
      end
      false
    end unless method_defined?(:value?)

    def keys
      arr = []
      each_pair {|k, v| arr << k}
      arr
    end unless method_defined?(:keys)

    def values
      arr = []
      each_pair {|k, v| arr << v}
      arr
    end unless method_defined?(:values)

    def each_key
      each_pair {|k, v| yield k}
    end unless method_defined?(:each_key)

    def each_value
      each_pair {|k, v| yield v}
    end unless method_defined?(:each_value)

    def empty?
      each_pair {|k, v| return false}
      true
    end unless method_defined?(:empty?)

    def size
      count = 0
      each_pair {|k, v| count += 1}
      count
    end unless method_defined?(:size)

    def marshal_dump
      raise TypeError, "can't dump hash with default proc" if @default_proc
      h = {}
      each_pair {|k, v| h[k] = v}
      h
    end

    def marshal_load(hash)
      initialize
      populate_from(hash)
    end

    undef :freeze

    private
    def initialize_copy(other)
      super
      populate_from(other)
    end

    def populate_from(hash)
      hash.each_pair {|k, v| self[k] = v}
      self
    end

    def validate_options_hash!(options)
      if (initial_capacity = options[:initial_capacity]) && (!initial_capacity.kind_of?(Fixnum) || initial_capacity < 0)
        raise ArgumentError, ":initial_capacity must be a positive Fixnum"
      end
      if (load_factor = options[:load_factor]) && (!load_factor.kind_of?(Numeric) || load_factor <= 0 || load_factor > 1)
        raise ArgumentError, ":load_factor must be a number between 0 and 1"
      end
    end
  end
end
