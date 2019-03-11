# frozen_string_literal: true

require 'persistent_enum/version'
require 'persistent_enum/acts_as_enum'

require 'active_support'
require 'active_support/inflector'
require 'active_record'
require 'activerecord-import'

# Provide a database-backed enumeration between indices and symbolic
# values. This allows us to have a valid foreign key which behaves like a
# enumeration. Values are cached at startup, and cannot be changed.
module PersistentEnum
  extend ActiveSupport::Concern
  class EnumTableInvalid < RuntimeError; end
  class MissingEnumTypeError < RuntimeError; end

  module ClassMethods
    def acts_as_enum(required_constants, name_attr: :name, sql_enum_type: nil, &constant_init_block)
      include ActsAsEnum
      enum_spec = EnumSpec.new(constant_init_block, required_constants, name_attr, sql_enum_type)
      initialize_acts_as_enum(enum_spec)
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
               raise NameError.new("#{target_class}: Invalid enum constant '#{enum_member}'") if m.nil?

               m.ordinal
             end
        write_attribute(foreign_key, id)
      end

      # All enum members must be valid
      validates foreign_key, inclusion: { in: ->(_r) { target_class.all_ordinals } }, allow_nil: true

      # New enum members must be currently active
      validates foreign_key, inclusion: { in: ->(_r) { target_class.ordinals } }, allow_nil: true, on: :create
    end
  end

  # Closes over the arguments to `acts_as_enum` so that it can be reloaded.
  EnumSpec = Struct.new(:constant_block, :constant_hash, :name_attr, :sql_enum_type) do
    def initialize(constant_block, constant_hash, name_attr, sql_enum_type)
      unless constant_block.nil? ^ constant_hash.nil?
        raise ArgumentError.new('Constants must be provided by exactly one of hash argument or builder block')
      end

      super(constant_block, constant_hash, name_attr.to_s, sql_enum_type)
      freeze
    end

    def required_members
      constant_hash || ConstantEvaluator.new.evaluate(&constant_block)
    end

    class ConstantEvaluator
      def evaluate(&block)
        @constants = {}
        self.instance_eval(&block)
        @constants
      end

      def constant!(name, **args)
        @constants[name] = args
      end

      def method_missing(name, **args)
        constant!(name, **args)
      end

      def respond_to_missing?(_name, _include_all = true)
        true
      end
    end
  end

  class << self
    # Given an 'enum-like' table with (id, name, ...) structure and a set of
    # enum members specified as either [name, ...] or {name: {attr: val, ...}, ...},
    # ensure that there is a row in the table corresponding to each name, and
    # cache the models as constants on the model class.
    #
    # When using a database such as postgresql that supports native enumerated
    # types, can additionally specify a native enum type to use as the primary
    # key. In this case, the required members will be added to the native type
    # by name using `ALTER TYPE` before insertion. This ensures that enum table
    # ids will have predictable values and can therefore be used in database
    # level constraints.
    def cache_constants(model, required_members, name_attr: 'name', required_attributes: nil, sql_enum_type: nil)
      # normalize member specification
      unless required_members.is_a?(Hash)
        required_members = required_members.each_with_object({}) { |c, h| h[c] = {} }
      end

      # Normalize symbols
      name_attr = name_attr.to_s
      required_members = required_members.each_with_object({}) do |(name, attrs), h|
        h[name.to_s] = attrs.transform_keys(&:to_s)
      end
      required_attributes = required_attributes.map(&:to_s) if required_attributes

      # We need to cope with (a) loading this class and (b) ensuring that all the
      # constants are defined (if not functional) in the case that the database
      # isn't present yet. If no database is present, create dummy values to
      # populate the constants.
      values =
        begin
          cache_constants_in_table(model, name_attr, required_members, required_attributes, sql_enum_type)
        rescue EnumTableInvalid => ex
          # If we're running the application in any way, under no circumstances
          # do we want to introduce the dummy models: crash out now. Our
          # conservative heuristic to detect a 'safe' loading outside the
          # application is whether there is a current Rake task.
          unless Object.const_defined?(:Rake) && Rake.try(:application)&.top_level_tasks.present?
            raise
          end

          # Otherwise, we want to try as hard as possible to allow the
          # application to be initialized enough to run the Rake task (e.g.
          # db:migrate).
          log_warning("Database table initialization error for model #{model.name}, "\
                      'initializing constants with dummy records instead: ' +
                      ex.message)
          cache_constants_in_dummy_class(model, name_attr, required_members, required_attributes, sql_enum_type)
        end

      return cache_values(model, values, name_attr)
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
    rescue ActiveRecord::NoDatabaseError
      puts "Database for model #{model.name} doesn't exist, no constants cached."
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

    def cache_constants_in_table(model, name_attr, required_members, required_attributes, sql_enum_type)
      begin
        unless model.table_exists?
          raise EnumTableInvalid.new("Database table for model #{model.name} doesn't exist")
        end
      rescue ActiveRecord::NoDatabaseError
        raise EnumTableInvalid.new("Database for model #{model.name} doesn't exist")
      end

      internal_attributes = ['id', name_attr]
      table_attributes = (model.column_names - internal_attributes)

      # If not otherwise specified, non-null attributes without defaults are required
      optional_attributes = model.columns.select { |col| col.null || !col.default.nil? }.map(&:name) - internal_attributes
      required_attributes ||= table_attributes - optional_attributes

      column_defaults = model.column_defaults

      unless (unknown_attributes = (required_attributes - table_attributes)).blank?
        log_warning("PersistentEnum error: required attributes #{unknown_attrs.inspect} for model #{model.name} not found in table - ignoring.")
        required_attributes -= unknown_attributes
      end

      unless model.connection.indexes(model.table_name).detect { |i| i.columns == [name_attr] && i.unique }
        raise EnumTableInvalid.new("detected missing unique index on '#{name_attr}'")
      end

      if model.connection.open_transactions > 0
        # This case particularly doesn't fall back to dummy initialization as it
        # indicates that the PersistentEnum wasn't initialized at startup: a
        # silent fallback to a dummy model could go unnoticed.
        raise RuntimeError.new("PersistentEnum model #{model.name} detected unsafe class initialization during a transaction: aborting.")
      end

      if sql_enum_type
        begin
          ensure_sql_enum_members(model.connection, required_members.keys, sql_enum_type)
        rescue MissingEnumTypeError
          log_warning("Database enum type missing for PersistentEnum #{model.name}: falling back to default id handling")
          sql_enum_type = nil
        end
      end

      expected_rows = required_members.map do |name, attrs|
        attr_names = attrs.keys

        if (extra_attrs = (attr_names - table_attributes)).present?
          log_warning("PersistentEnum error: specified attributes #{extra_attrs.inspect} for model #{model.name} missing from table - ignoring.")
          attrs = attrs.except(*extra_attrs)
        end

        if (missing_attrs = (required_attributes - attr_names)).present?
          raise EnumTableInvalid.new("enum member error: required attributes #{missing_attrs.inspect} not provided")
        end

        new_attrs = attrs.dup
        new_attrs[name_attr] = name
        new_attrs['id'] = name if sql_enum_type
        (optional_attributes - attr_names).each do |default_attr|
          new_attrs[default_attr] = column_defaults[default_attr]
        end
        new_attrs
      end

      model.transaction do
        upsert_records(model, name_attr, expected_rows)
        model.where(name_attr => required_members.keys).to_a
      end
    end

    def cache_constants_in_dummy_class(model, name_attr, required_members, required_attributes, sql_enum_type)
      dummyclass = build_dummy_class(model, name_attr)

      next_id = 999999999

      required_members.map do |member_name, attrs|
        id = sql_enum_type ? member_name : (next_id += 1)
        dummyclass.new(id, member_name, attrs)
      end
    end

    def upsert_records(model, name_attr, expected_rows)
      # Not all rows will have the same attributes to upsert: group and upsert by attributes
      expected_rows.group_by(&:keys).each do |row_attrs, rows|
        upsert_columns = row_attrs - [name_attr, 'id']

        case model.connection.adapter_name
        when 'PostgreSQL'
          model.import!(rows, on_duplicate_key_update: { conflict_target: [name_attr], columns: upsert_columns })
        when 'Mysql2'
          if upsert_columns.present?
            # Even for identical rows in the same order, a INSERT .. ON DUPLICATE
            # KEY UPDATE can deadlock with itself. Obtain write locks in advance.
            model.lock('FOR UPDATE').order(:id).pluck(:id)
            model.import!(rows, on_duplicate_key_update: upsert_columns)
          else
            model.import!(rows, on_duplicate_key_ignore: true)
          end
        else
          # No upsert support: use first_or_create optimistically
          rows.each do |row|
            record = model.lock.where(name_attr => row[name_attr]).first_or_create!(row.except('id', name_attr))
            record.assign_attributes(row)
            record.validate!
            record.save! if record.changed?
          end
        end
      end
    end

    ENUM_TYPE_LOCK_KEY = 0x757a6cafedc6084d # Random 64-bit key

    def ensure_sql_enum_members(connection, names, sql_enum_type)
      # It may be the case that an enum type doesn't yet exist despite the table
      # existing, for example if the table is presently being migrated to an
      # enum type. If this is the case, warn and fall back to standard id handling.
      type_exists = ActiveRecord::Base.connection.select_value(
        "SELECT true FROM pg_type WHERE typname = #{connection.quote(sql_enum_type)}")
      raise MissingEnumTypeError.new unless type_exists

      # ALTER TYPE may not be performed within a transaction: obtain a
      # session-level advisory lock to prevent racing.
      begin
        connection.execute("SELECT pg_advisory_lock(#{ENUM_TYPE_LOCK_KEY})")

        quoted_type = connection.quote_table_name(sql_enum_type)
        current_members = connection.select_values(<<~SQL)
          SELECT unnest(enum_range(null::#{quoted_type}, null::#{quoted_type}));
        SQL

        (names - current_members).each do |name|
          connection.execute("ALTER TYPE #{quoted_type} ADD VALUE #{connection.quote(name)}")
        end
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{ENUM_TYPE_LOCK_KEY})")
      end
    end

    # Set each value as a constant on this class. If reinitializing, only
    # replace if the enum constant has changed, otherwise update attributes as
    # necessary.
    def cache_values(model, values, name_attr)
      values.map do |value|
        constant_name = constant_name(value.read_attribute(name_attr))

        if model.const_defined?(constant_name, false)
          existing_value = model.const_get(constant_name, false)
          if existing_value.is_a?(AbstractDummyModel) ||
             existing_value.read_attribute(name_attr) != value.read_attribute(name_attr)
          then
            # Replace with new value
            model.send(:remove_const, constant_name)
            model.const_set(constant_name, value)
          elsif existing_value.attributes != value.attributes
            existing_value.reload.freeze
          else
            existing_value
          end
        else
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

    def log_warning(message)
      if (logger = ActiveRecord::Base.logger)
        logger.warn(message)
      else
        STDERR.puts(message)
      end
    end

    class AbstractDummyModel
      attr_reader :ordinal, :enum_constant, :attributes

      def initialize(id, name, attributes = {})
        @ordinal       = id
        @enum_constant = name
        @attributes    = attributes.with_indifferent_access
        freeze
      end

      def to_sym
        enum_constant.to_sym
      end

      alias id ordinal

      def read_attribute(attr)
        case attr.to_s
        when 'id'
          ordinal
        when self.class.name_attr.to_s
          enum_constant
        else
          @attributes[attr]
        end
      end

      alias [] read_attribute

      def method_missing(meth, *args)
        if attributes.has_key?(meth)
          unless args.empty?
            raise ArgumentError.new("wrong number of arguments (#{args.size} for 0)")
          end

          attributes[meth]
        else
          super
        end
      end

      def respond_to_missing?(meth, include_private = false)
        attributes.has_key?(meth) || super
      end

      def freeze
        @ordinal.freeze
        @enum_constant.freeze
        @attributes.freeze
        @attributes.each do |k, v|
          k.freeze
          v.freeze
        end
        super
      end

      def self.for_name(name_attr)
        Class.new(self) do
          define_singleton_method(:name_attr, -> { name_attr })
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

require 'persistent_enum/railtie' if defined?(Rails)
