# -*- coding: utf-8 -*-
require "persistent_enum/version"
require "persistent_enum/acts_as_enum"

require "active_support"
require "active_support/inflector"
require "active_record"

# Provide a database-backed enumeration between indices and symbolic
# values. This allows us to have a valid foreign key which behaves like a
# enumeration. Values are cached at startup, and cannot be changed.
module PersistentEnum
  extend ActiveSupport::Concern

  module ClassMethods
    def acts_as_enum(required_constants, name_attr: :name, &constant_init_block)
      include ActsAsEnum

      if block_given?
        unless required_constants.blank?
          raise ArgumentError.new("Constants may not be provided both by argument and builder block")
        end
        required_constants = ConstantEvaluator.new.evaluate(&constant_init_block)
      end

      unless required_constants.present?
        raise ArgumentError.new("No enum constants specified")
      end

      initialize_acts_as_enum(required_constants, name_attr)
    end

    # Sets up a association with an enumeration record type. Key resolution is
    # done via the enumeration type's cache rather than ActiveRecord. The
    # setter accepts either a model type or the enum constant name as a symbol
    # or string.
    def belongs_to_enum(enum_name, class_name: enum_name.to_s.camelize, foreign_key: "#{enum_name}_id")
      target_class = class_name.constantize

      define_method(enum_name) do
        target_id = read_attribute(foreign_key)
        target_class[target_id]
      end

      define_method("#{enum_name}=") do |enum_member|
        id = case enum_member
             when nil
               nil
             when target_class
               enum_member.ordinal
             else
               m = target_class.value_of(enum_member)
               raise NameError.new("#{target_class.to_s}: Invalid enum constant '#{enum_member}'") if m.nil?
               m.ordinal
             end
        write_attribute(foreign_key, id)
      end

      # All enum members must be valid
      validates foreign_key, inclusion: { in: ->(r){ target_class.all_ordinals } }, allow_nil: true

      # New enum members must be currently active
      validates foreign_key, inclusion: { in: ->(r){ target_class.ordinals } }, allow_nil: true, on: :create
    end
  end

  class ConstantEvaluator
    def evaluate(&block)
      @constants = {}
      self.instance_eval(&block)
      @constants
    end

    def method_missing(name, **args)
      @constants[name] = args
    end
  end

  class << self
    # Given an 'enum-like' table with (id, name, ...) structure and a set of
    # enum members specified as either [name, ...] or {name: {attr: val, ...}, ...},
    # ensure that there is a row in the table corresponding to each name, and
    # cache the models as constants on the model class.
    def cache_constants(model, required_members, name_attr: :name)
      # normalize member specification
      unless required_members.is_a?(Hash)
        required_members = required_members.each_with_object({}) { |c, h| h[c] = {} }
      end

      # We need to cope with (a) loading this class and (b) ensuring that all the
      # constants are defined (if not functional) in the case that the database
      # isn't present yet. If no database is present, create dummy values to
      # populate the constants.
      if model.table_exists?
        table_attributes = model.attribute_names - ["id", name_attr.to_s]

        if model.connection.open_transactions > 0
          raise RuntimeError.new("PersistentEnum model #{model.name} detected unsafe class initialization during a transaction: aborting.")
        end

        values = model.transaction do
          values_by_name = model.where(name_attr => required_members.keys).index_by { |m| m.read_attribute(name_attr) }

          # Update or create
          required_members.each do |name, attrs|
            name = name.to_s
            attr_names = attrs.keys.map(&:to_s)

            if attr_names != table_attributes
              raise ArgumentError.new("Enum member attribute mismatch: expected #{table_attributes.inspect}, received #{attr_names.inspect}")
            end

            current = values_by_name[name]

            if current.present?
              current.assign_attributes(attrs)
              current.save! if current.changed?
            else
              values_by_name[name] = model.create(attrs.merge(name_attr => name))
            end
          end
          values_by_name.values
        end
      else
        puts "Database table for model #{model.name} doesn't exist, initializing constants with dummy records instead."
        dummyclass = build_dummy_class(model, name_attr)

        next_id = 999999999
        values = required_members.map do |member_name, attrs|
          dummyclass.new(next_id += 1, member_name.to_s, attrs)
        end
      end

      cache_values(model, values, name_attr)

      values
    end

    # Given an 'enum-like' table with (id, name, ...) structure, load existing
    # records from the database and cache them in constants on this class
    def cache_records(model, name_attr: :name)
      if model.table_exists?
        values = model.scoped
        cache_values(model, values, name_attr)
      else
        puts "Database table for model #{model.name} doesn't exist, no constants cached."
      end
    end

    def dummy_class(model, name_attr)
      if model.const_defined?(:DummyModel, false)
        dummy_class = model::DummyModel
        unless dummy_class.superclass == AbstractDummyModel && dummy_class.name_attr == name_attr
          raise NameError.new("PersistentEnum dummy class type mismatch: '#{dummy_class.inspect}' does not match '#{model.name}'")
        end
        dummy_class
      else
        nil
      end
    end

    private

    # Set each value as a constant on this class. If reloading, only update if
    # it's changed.
    def cache_values(model, values, name_attr)
      values.each do |value|
        constant_name = constant_name(value.read_attribute(name_attr))
        unless model.const_defined?(constant_name, false) && model.const_get(constant_name, false) == value
          model.const_set(constant_name, value)
        end
      end
    end

    def constant_name(member_name)
      value = member_name.strip.gsub(/[^\w\s-]/, '_').underscore
      return nil if value.blank?
      value.gsub!(/\s+/, '_')
      value.gsub!(/_{2,}/, '_')
      value.upcase!
      value
    end

    class AbstractDummyModel
      attr_reader :ordinal, :enum_constant

      def initialize(id, name, attributes = {})
        @ordinal       = id
        @enum_constant = name
        @attributes    = attributes.with_indifferent_access
      end

      def to_sym
        enum_constant.to_sym
      end

      alias_method :id, :ordinal

      def read_attribute(attr)
        case attr.to_s
        when "id"
          ordinal
        when self.class.name_attr.to_s
          enum_constant
        else
          @attributes[attr]
        end
      end

      alias_method :[], :read_attribute

      def method_missing(m, *args)
        m = m.to_s
        case
        when m == "id"
          ordinal
        when m == self.class.name_attr.to_s
          enum_constant
        when @attributes.has_key?(m)
          if args.size > 0
            raise ArgumentError.new("wrong number of arguments (#{args.size} for 0)")
          end
          @attributes[m]
        else
          super
        end
      end

      def self.for_name(name_attr)
        Class.new(self) do
          define_singleton_method(:name_attr, ->{name_attr})
          alias_method name_attr, :enum_constant
        end
      end
    end

    def build_dummy_class(model, name_attr)
      dummy_model = PersistentEnum.dummy_class(model, name_attr)
      return dummy_model if dummy_model.present?

      dummy_model = AbstractDummyModel.for_name(name_attr)
      model.const_set(:DummyModel, dummy_model)
      dummy_model
    end
  end

  ActiveRecord::Base.send(:include, self)
end
