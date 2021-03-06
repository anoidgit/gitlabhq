require_dependency 'declarative_policy/cache'
require_dependency 'declarative_policy/condition'
require_dependency 'declarative_policy/dsl'
require_dependency 'declarative_policy/preferred_scope'
require_dependency 'declarative_policy/rule'
require_dependency 'declarative_policy/runner'
require_dependency 'declarative_policy/step'

require_dependency 'declarative_policy/base'

require 'thread'

module DeclarativePolicy
  CLASS_CACHE_MUTEX = Mutex.new
  CLASS_CACHE_IVAR = :@__DeclarativePolicy_CLASS_CACHE

  class << self
    def policy_for(user, subject, opts = {})
      cache = opts[:cache] || {}
      key = Cache.policy_key(user, subject)

      cache[key] ||= class_for(subject).new(user, subject, opts)
    end

    def class_for(subject)
      return GlobalPolicy if subject == :global
      return NilPolicy if subject.nil?

      subject = find_delegate(subject)

      class_for_class(subject.class)
    end

    private

    # This method is heavily cached because there are a lot of anonymous
    # modules in play in a typical rails app, and #name performs quite
    # slowly for anonymous classes and modules.
    #
    # See https://bugs.ruby-lang.org/issues/11119
    #
    # if the above bug is resolved, this caching could likely be removed.
    def class_for_class(subject_class)
      unless subject_class.instance_variable_defined?(CLASS_CACHE_IVAR)
        CLASS_CACHE_MUTEX.synchronize do
          # re-check in case of a race
          break if subject_class.instance_variable_defined?(CLASS_CACHE_IVAR)

          policy_class = compute_class_for_class(subject_class)
          subject_class.instance_variable_set(CLASS_CACHE_IVAR, policy_class)
        end
      end

      policy_class = subject_class.instance_variable_get(CLASS_CACHE_IVAR)
      raise "no policy for #{subject.class.name}" if policy_class.nil?
      policy_class
    end

    def compute_class_for_class(subject_class)
      subject_class.ancestors.each do |klass|
        next unless klass.name

        begin
          policy_class = "#{klass.name}Policy".constantize

          # NOTE: the < operator here tests whether policy_class
          # inherits from Base. We can't use #is_a? because that
          # tests for *instances*, not *subclasses*.
          return policy_class if policy_class < Base
        rescue NameError
          nil
        end
      end
    end

    def find_delegate(subject)
      seen = Set.new

      while subject.respond_to?(:declarative_policy_delegate)
        raise ArgumentError, "circular delegations" if seen.include?(subject.object_id)
        seen << subject.object_id
        subject = subject.declarative_policy_delegate
      end

      subject
    end
  end
end
