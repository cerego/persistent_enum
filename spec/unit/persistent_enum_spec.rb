# frozen_string_literal: true

# rubocop:disable Performance/HashEachMethods, Style/Semicolon, Lint/MissingCopEnableDirective

require 'persistent_enum'
require 'byebug'

require_relative '../spec_helper'

RSpec.describe PersistentEnum, :database do
  CONSTANTS = [:One, :Two, :Three, :Four].freeze

  before(:context) do
    DatabaseHelper.initialize_database
  end

  before(:each) do
    if ActiveRecord::Base.logger
      allow(ActiveRecord::Base.logger).to receive(:warn).and_call_original
    else
      ActiveRecord::Base.logger = spy(:logger)
    end
    initialize_test_models
  end

  after(:each) do
    destroy_test_models
    unless ActiveRecord::Base.logger.is_a?(Logger)
      ActiveRecord::Base.logger = nil
    end
  end

  shared_examples "acts like an enum" do
    # abstract :model

    it "looks up each value" do
      CONSTANTS.each do |c|
        e = model.value_of(c)
        expect(e).to               be_present
        expect(e.enum_constant).to be_a(String)
        expect(e.to_sym).to        eq(c)
        expect(e).to               eq(model[e.ordinal])
        expect(e).to               eq(model.const_get(c.upcase))
        expect(e).to               be_frozen
        expect(e.enum_constant).to be_frozen
      end
    end

    it "returns all values from the cache" do
      expect(model.values.map(&:to_sym)).to contain_exactly(*CONSTANTS)
    end
  end

  shared_examples "acts like a persisted enum" do
    # abstract :model

    include_examples "acts like an enum"

    context "a referring model" do
      let(:foreign_name) { model.model_name.singular }
      let(:foreign_key) { foreign_name + "_id" }

      let(:other_model) do
        foreign_name = foreign_name()
        foreign_key_type = model.columns.detect { |x| x.name == "id" }.sql_type

        create_table = ->(t) {
          t.references foreign_name, type: foreign_key_type, foreign_key: true
        }

        create_test_model(:referrer, create_table) do
          belongs_to_enum foreign_name
        end
      end

      it "can be created from enum value" do
        model.values.each do |v|
          t = other_model.new(foreign_name => v)
          expect(t).to be_valid
                   .and have_attributes(foreign_name => v,
                                        foreign_key  => v.ordinal)
        end
      end

      it "can be created from constant name" do
        model.values.each do |v|
          t = other_model.new(foreign_name => v.enum_constant)
          expect(t).to be_valid
                   .and have_attributes(foreign_name => v,
                                        foreign_key  => v.ordinal)
        end
      end

      it "can be created from ordinal" do
        model.values.each do |v|
          t = other_model.new(foreign_key => v.ordinal)
          expect(t).to be_valid
                   .and have_attributes(foreign_name => v,
                                        foreign_key  => v.ordinal)
        end
      end

      it "can be created with null foreign key" do
        t = other_model.new
        expect(t).to be_valid
      end

      it "can not be created with invalid foreign key" do
        t = other_model.new(foreign_key => -1)
        expect(t).not_to be_valid
      end

      it "can not be created with invalid foreign constant" do
        expect {
          other_model.new(foreign_name => :BadConstant)
        }.to raise_error(NameError)
      end
    end
  end

  context "with an enum model" do
    let(:model) do
      create_test_model(:with_table, ->(t) { t.string :name; t.index [:name], unique: true }) do
        acts_as_enum(CONSTANTS)
      end
    end

    it_behaves_like "acts like a persisted enum"

    it "returns all values from the database" do
      expect(model.all.map(&:to_sym)).to contain_exactly(*CONSTANTS)
    end

    it "is immutable" do
      expect { model.create(name: "foo") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)

      expect { model::ONE.name = "foo" }
        .to raise_error(RuntimeError, /can't modify frozen/i) # Frozen object

      expect { model.first.update_attribute(:name, "foo") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)

      expect { model.first.destroy }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  context "with a validation on the model" do
    let(:model) do
      create_test_model(:with_table, ->(t) { t.string :name; t.index [:name], unique: true }) do
        yield if block_given?
        validates :name, exclusion: { in: [CONSTANTS.first.to_s] }
        acts_as_enum(CONSTANTS)
      end
    end

    it "does not admit invalid values" do
      expect { model }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    context "with existing invalid values" do
      let(:model) do
        super() do
          create(name: CONSTANTS.first.to_s)
        end
      end

      it "does not admit invalid values" do
        expect { model }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  def self.with_dummy_rake(&block)
    context "with rake defined" do
      around(:each) do |example|
        rake = OpenStruct.new(application: OpenStruct.new(top_level_tasks: [:fake]))
        Object.const_set(:Rake, rake)
        example.run
        Object.send(:remove_const, :Rake)
      end

      instance_exec(&block)
    end
  end

  shared_examples "falls back to a dummy model" do |name_attr: 'name', sql_enum: false|
    context "without rake defined" do
      it "raises the error directly" do
        expect { model }.to raise_error(PersistentEnum::EnumTableInvalid)
      end
    end

    with_dummy_rake do
      it "warns that it is falling back" do
        expect(model).to be_present
        expect(ActiveRecord::Base.logger)
          .to have_received(:warn)
                .with(a_string_matching(/Database table initialization error.*dummy records/))
      end

      it "makes a dummy model" do
        dummy_model = PersistentEnum.dummy_class(model, name_attr)
        expect(dummy_model).to be_present
        expect(model.values).to all(be_kind_of(dummy_model))
      end

      it "initializes dummy values correctly" do
        model.values.each do |val|
          i = val.ordinal
          enum_type = sql_enum ? String : Integer
          expect(i).to be_a(enum_type)
          expect(val.id).to    eq(i)
          expect(val["id"]).to eq(i)
          expect(val[:id]).to  eq(i)

          c = val.enum_constant
          expect(c).to be_a(String)
          expect(val.name).to    eq(c)
          expect(val["name"]).to eq(c)
          expect(val[:name]).to  eq(c)
        end
      end
    end
  end

  context "with a table-less enum" do
    let(:model) do
      create_test_model(:without_table, nil, create_table: false) do
        acts_as_enum(CONSTANTS)
      end
    end

    it_behaves_like "falls back to a dummy model"

    with_dummy_rake do
      it_behaves_like "acts like an enum"
    end
  end

  context "with existing data" do
    let(:initial_ordinal) { 9998 }
    let(:initial_constant) { CONSTANTS.first }

    let(:existing_ordinal) { 9999 }
    let(:existing_constant) { :Hello }

    let!(:model) do
      model = create_test_model(:with_existing, ->(t) { t.string :name; t.index [:name], unique: true })
      @initial_value  = model.create(id: initial_ordinal, name: initial_constant.to_s)
      @existing_value = model.create(id: existing_ordinal, name: existing_constant.to_s)
      model.acts_as_enum(CONSTANTS)
      model
    end

    it_behaves_like "acts like a persisted enum"

    let(:expected_all) { (CONSTANTS + [existing_constant]) }
    let(:expected_required) { CONSTANTS }

    it "caches required values" do
      expect(model.values.map(&:to_sym)).to contain_exactly(*expected_required)
    end

    it "caches all values" do
      expect(model.all_values.map(&:to_sym)).to contain_exactly(*expected_all)
    end

    it "loads all values" do
      expect(model.all.map(&:to_sym)).to contain_exactly(*expected_all)
    end

    let(:required_ordinals) { expected_required.map { |name| model.value_of!(name).ordinal } }
    let(:all_ordinals) { expected_all.map { |name| model.value_of!(name).ordinal } }

    it "caches required ordinals" do
      expect(model.ordinals).to contain_exactly(*required_ordinals)
    end

    it "caches all ordinals" do
      expect(model.all_ordinals).to contain_exactly(*all_ordinals)
    end

    it "loads all ordinals" do
      expect(model.pluck(:id)).to contain_exactly(*all_ordinals)
    end

    it "respects initial value" do
      expect(model[initial_ordinal]).to eq(@initial_value)
      expect(model.value_of(initial_constant)).to eq(@initial_value)
      expect(model.where(name: initial_constant).first).to eq(@initial_value)
    end

    it "respects existing value" do
      expect(model[existing_ordinal]).to eq(@existing_value)
      expect(model.value_of(existing_constant)).to eq(@existing_value)
      expect(model.where(name: existing_constant).first).to eq(@existing_value)
    end

    it "marks existing model as non-active" do
      expect(model[existing_ordinal]).to_not be_active
    end
  end

  context "with cached constants" do
    let(:model) do
      create_test_model(:with_constants, ->(t) { t.string :name; t.index [:name], unique: true }) do
        PersistentEnum.cache_constants(self, CONSTANTS)
      end
    end

    it "caches all the constants" do
      CONSTANTS.each do |c|
        cached = model.const_get(c.upcase)
        expect(cached).to be_present
        expect(cached.name).to eq(c.to_s)

        loaded = model.find_by(name: c.to_s)
        expect(loaded).to be_present.and eq(cached)
      end
    end
  end

  context "with complex constant names" do
    let(:test_constants) do
      {
        "CamelCase"             => "CAMEL_CASE",
        :Symbolic               => "SYMBOLIC",
        "with.punctuation"      => "WITH_PUNCTUATION",
        "multiple_.underscores" => "MULTIPLE_UNDERSCORES"
      }
    end

    let(:model) do
      test_constants = test_constants()
      create_test_model(:with_complex_names, ->(t) { t.string :name; t.index [:name], unique: true }) do
        PersistentEnum.cache_constants(self, test_constants.keys)
      end
    end

    it "caches the constant name as we expect" do
      test_constants.each do |expected_name, expected_constant|
        val = model.const_get(expected_constant)
        expect(val).to be_present
        expect(val.name).to eq(expected_name.to_s)
      end
    end
  end

  context "with extra fields" do
    let(:members) do
      {
        :One   => { count: 1 },
        :Two   => { count: 2 },
        :Three => { count: 3 },
        :Four  => { count: 4 }
      }
    end

    shared_examples "acts like an enum with extra fields" do
      it "has all expected members with expected values" do
        members.each do |name, fields|
          ev = model.value_of(name)

          # Ensure it exists and is correctly saved
          expect(ev).to be_present
          expect(model.values).to include(ev)
          expect(model.all_values).to include(ev)
          expect(ev).to eq(model[ev.ordinal])

          # Ensure it's correctly saved
          if model.table_exists?
            expect(model.where(name: name).first).to eq(ev)
          end

          # and that fields have been correctly set
          fields.each do |fname, fvalue|
            expect(ev[fname]).to eq(fvalue)
          end
        end
      end
    end

    shared_examples "acts like a persisted enum with extra fields" do
      include_examples "acts like an enum with extra fields"
    end

    context "providing a hash" do
      let(:model) do
        members = members()
        create_test_model(:with_extra_field, ->(t) { t.string :name; t.integer :count; t.index [:name], unique: true }) do
          # pre-existing matching, non-matching, and outdated data
          create(name: "One", count: 3)
          create(name: "Two", count: 2)
          create(name: "Zero", count: 0)

          acts_as_enum(members)
        end
      end

      it_behaves_like "acts like a persisted enum"
      it_behaves_like "acts like a persisted enum with extra fields"

      it "keeps outdated data" do
        z = model.value_of("Zero")
        expect(z).to be_present
        expect(model[z.ordinal]).to eq(z)
        expect(z.count).to eq(0)
        expect(model.all_values).to include(z)
        expect(model.values).not_to include(z)
      end

      context "when reinitializing" do
        let!(:model) { super() }

        it "uses the same constant" do
          old_constant = model.const_get(:ONE)
          model.reinitialize_acts_as_enum
          new_constant = model.const_get(:ONE)
          expect(new_constant).to equal(old_constant)
          expect(new_constant).to equal(model.value_of("One"))
        end

        it "handles a change in an attribute" do
          old_constant = model.const_get(:ONE)

          state = model._acts_as_enum_state
          new_spec =
            PersistentEnum::EnumSpec.new(
              nil,
              state.required_members.merge({ "One" => { count: 1111 } }),
              state.name_attr,
              state.sql_enum_type)
          model.initialize_acts_as_enum(new_spec)

          new_constant = model.const_get(:ONE)
          expect(new_constant.count).to eq(1111)
          expect(new_constant).to equal(old_constant)
          expect(new_constant).to equal(model.value_of("One"))
        end

        it "handles a change in enum constant by replacing" do
          model.where(name: "One").update_all(name: "oNe")
          old_constant = model.const_get(:ONE).reload
          # Note this has completely broken the enum indexing. Not relevant to test.
          expect(old_constant.name).to eq("oNe")

          model.reinitialize_acts_as_enum
          new_constant = model.const_get(:ONE)
          expect(new_constant.name).to eq("One")
          expect(new_constant).not_to equal(old_constant)
          expect(new_constant).to equal(model.value_of("One"))
        end
      end
    end

    context "using builder interface" do
      let(:model) do
        create_test_model(:with_extra_field_using_builder, ->(t) { t.string :name; t.integer :count; t.index [:name], unique: true }) do
          acts_as_enum(nil) do
            One(count: 1)
            Two(count: 2)
            constant!(:Three, count: 3)
            Four(count: 4)
          end
        end
      end

      it_behaves_like "acts like a persisted enum"
      it_behaves_like "acts like a persisted enum with extra fields"
    end

    context "with closed over builder" do
      let(:model) do
        v = 0
        create_test_model(:with_dynamic_builder, ->(t) { t.string :name; t.integer :count; t.index [:name], unique: true }) do
          acts_as_enum(nil) do
            Member(count: (v += 1))
          end
        end
      end

      it "can reinitialize with a changed value" do
        expect(model.value_of("Member").count).to eq(1)
        model.reinitialize_acts_as_enum
        expect(model.value_of("Member").count).to eq(2)
      end
    end

    context "without table" do
      let(:model) do
        members = members()
        create_test_model(:with_extra_field_without_table, nil, create_table: false) do
          acts_as_enum(members)
        end
      end

      it_behaves_like "falls back to a dummy model"

      with_dummy_rake do
        it_behaves_like "acts like an enum"
        it_behaves_like "acts like an enum with extra fields"
      end
    end

    context "with missing required attributes" do
      let(:model) do
        create_test_model(:test_invalid_args_a, ->(t) { t.string :name; t.integer :count, null: false; t.index [:name], unique: true }) do
          acts_as_enum([:Bad])
        end
      end

      it_behaves_like "falls back to a dummy model"

      with_dummy_rake do
        it "warns that the required attributes were missing" do
          expect(model.logger)
            .to have_received(:warn)
                  .with(a_string_matching(/required attributes.*not provided/))
        end
      end
    end

    context "with attributes with defaults" do
      let(:model) do
        create_test_model(:test_invalid_args_b, ->(t) {
                            t.string :name
                            t.integer :count, default: 1, null: false
                            t.integer :maybe
                            t.index [:name], unique: true
                          }) do
          acts_as_enum(nil) do
            One()
            Two(count: 2)
            Three(maybe: 1)
          end
        end
      end

      it "allows defaults to be omitted" do
        o = model.value_of("One")
        expect(o).to be_present
        expect(o.count).to eq(1)
        expect(o.maybe).to eq(nil)

        t = model.value_of("Two")
        expect(t).to be_present
        expect(t.count).to eq(2)
        expect(t.maybe).to eq(nil)

        r = model.value_of("Three")
        expect(r).to be_present
        expect(r.count).to eq(1)
        expect(r.maybe).to eq(1)
      end
    end

    it "warns if nonexistent attributes are provided" do
      create_test_model(:test_invalid_args_c, ->(t) { t.string :name; t.index [:name], unique: true }) do
        acts_as_enum({ :One => { incorrect: 1 } })
      end

      expect(ActiveRecord::Base.logger)
        .to have_received(:warn)
        .with(a_string_matching(/missing from table/))
    end
  end

  context "using a postgresql enum valued id", :postgresql do
    let(:name) { "with_enum_id" }
    let(:enum_type) { "#{name}_type" }

    context "with table" do
      before(:each) do
        ActiveRecord::Base.connection.execute("CREATE TYPE #{enum_type} AS ENUM ()")
        ActiveRecord::Base.connection.create_table(name.pluralize, id: false) do |t|
          t.column :id, enum_type, primary_key: true, null: false
          t.string :name
          t.index [:name], unique: true
        end
      end

      after(:each) do
        ActiveRecord::Base.connection.execute("DROP TYPE #{enum_type} CASCADE")
      end

      let(:model) do
        enum_type = enum_type()
        create_test_model(:with_enum_id, nil, create_table: false) do
          acts_as_enum(CONSTANTS, sql_enum_type: enum_type)
        end
      end

      it_behaves_like "acts like a persisted enum"
    end

    context "without table" do
      let(:model) do
        enum_type = enum_type()
        create_test_model(:no_table_enum_id, nil, create_table: false) do
          acts_as_enum(CONSTANTS, sql_enum_type: enum_type)
        end
      end

      it_behaves_like "falls back to a dummy model", sql_enum: true
      with_dummy_rake do
        it_behaves_like "acts like an enum"
      end
    end
  end

  context "with the name of the enum value column changed" do
    let(:model) do
      create_test_model(:test_new_name, ->(t) { t.string :namey; t.index [:namey], unique: true }) do
        acts_as_enum(CONSTANTS, name_attr: :namey)
      end
    end
    it_behaves_like "acts like a persisted enum"
  end

  it "refuses to create a table in a transaction" do
    expect {
      ActiveRecord::Base.transaction do
        create_test_model(:test_create_in_transaction, ->(t) { t.string :name; t.index [:name], unique: true }) do
          acts_as_enum([:A, :B])
        end
      end
    }.to raise_error(RuntimeError, /unsafe class initialization during/)
  end

  context "without an index on the enum constant" do
    let(:model) do
      create_test_model(:test_create_without_index, ->(t) { t.string :name }) do
        acts_as_enum([:A, :B])
      end
    end

    it_behaves_like "falls back to a dummy model"

    with_dummy_rake do
      it "warns that the unique index was missing" do
        expect(model.logger)
          .to have_received(:warn)
                .with(a_string_matching(/missing unique index/))
      end
    end
  end

  context "without a unique index on the enum constant" do
    let(:model) do
      create_test_model(:test_create_without_index, ->(t) { t.string :name; t.index [:name] }) do
        acts_as_enum([:A, :B])
      end
    end

    it_behaves_like "falls back to a dummy model"

    with_dummy_rake do
      it "warns that the unique index was missing" do
        expect(model.logger)
          .to have_received(:warn)
                .with(a_string_matching(/missing unique index/))
      end
    end
  end

  context "with an empty constants array" do
    let(:initial_ordinal) { 9998 }
    let(:initial_constant) { CONSTANTS.first }

    let(:model) do
      model = create_test_model(:with_empty_constants, ->(t) { t.string :name; t.index [:name], unique: true })
      @prior_value = model.create!(id: initial_ordinal, name: initial_constant.to_s)
      model.acts_as_enum([])
      model
    end

    it "looks up the existing value" do
      expect(model.value_of(initial_constant)).to eq(@prior_value)
      expect(model[initial_ordinal]).to eq(@prior_value)
    end

    it "caches the existing value" do
      expect(model.all_values).to eq([@prior_value])
    end
  end
end
