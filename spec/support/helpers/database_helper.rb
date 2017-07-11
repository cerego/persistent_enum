require 'yaml'
require 'active_record'

module DatabaseHelper
  def initialize_database
    db_config_path = File.join(File.dirname(__FILE__), '../config/database.yml')
    db_config = YAML.load(File.open(db_config_path))
    raise "Test database configuration missing" unless db_config["test"]
    ActiveRecord::Base.establish_connection(db_config["test"])

    @test_models = []
  end

  def create_test_model(name, columns, create_table: true, &block)
    if create_table
      table_name = name.to_s.pluralize
      ActiveRecord::Base.connection.create_table(table_name, &columns)
    end

    model_name = name.to_s.classify
    clazz = Class.new(ActiveRecord::Base)
    Object.const_set(model_name, clazz)
    clazz.primary_key = :id
    clazz.class_eval(&block) if block_given?
    clazz.reset_column_information
    @test_models << clazz
    clazz
  end

  def destroy_test_models
    @test_models.each do |m|
      destroy_test_model(m.name)
    end
    @test_models.clear
  end

  def destroy_test_model(name)
    model_name = name.to_s.classify
    clazz = Object.const_get(model_name)
    if !clazz.nil?
      table_name = clazz.table_name
      if clazz.table_exists?
        clazz.connection.drop_table(table_name, force: :cascade)
      end
      Object.send(:remove_const, model_name)
      ActiveSupport::Dependencies::Reference.clear!
    end
  end
end
