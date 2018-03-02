require 'yaml'
require 'active_record'

module DatabaseHelper
  def self.db_env
    ENV.fetch('TEST_DATABASE_ENVIROMENT', 'postgresql')
  end

  def self.initialize_database
    db_config_path = File.join(File.dirname(__FILE__), '../config/database.yml')
    db_config = YAML.safe_load(File.open(db_config_path))
    raise "Test database configuration missing" unless db_config[db_env]
    ActiveRecord::Base.establish_connection(db_config[db_env])

    if ENV["DEBUG"]
      ActiveRecord::Base.logger = Logger.new(STDERR)
      ActiveRecord::Base.logger.level = Logger::DEBUG
    end
    db_env
  end

  def initialize_test_models
    @test_models = []
  end

  def create_test_model(name, columns, create_table: true, &block)
    if create_table
      table_name = name.to_s.pluralize
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{table_name}")
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
    @test_models.reverse_each do |m|
      destroy_test_model(m.name)
    end
    @test_models.clear
  end

  def destroy_test_model(name)
    model_name = name.to_s.classify
    clazz = Object.const_get(model_name)
    unless clazz.nil?
      table_name = clazz.table_name
      if clazz.table_exists?
        clazz.connection.drop_table(table_name, force: :cascade)
      end
      Object.send(:remove_const, model_name)
      ActiveSupport::Dependencies::Reference.clear!
    end
  end
end
