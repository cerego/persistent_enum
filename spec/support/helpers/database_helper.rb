# frozen_string_literal: true

require 'yaml'
require 'active_record'

module DatabaseHelper
  def self.db_env
    ENV.fetch('TEST_DATABASE_ENVIRONMENT', 'postgresql')
  end

  def self.initialize_database
    if (url = ENV['DATABASE_URL'])
      db_config = url
    else
      db_config_path = File.join(File.dirname(__FILE__), '../config/database.yml')
      db_config_data = File.read(db_config_path)
      db_config_data = ERB.new(db_config_data).result
      db_config = YAML.safe_load(db_config_data)
      raise 'Test database configuration missing' unless db_config[db_env]

      db_config = db_config[db_env]
    end

    ActiveRecord::Base.establish_connection(db_config)

    if ENV['DEBUG']
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
    @test_models << clazz
    clazz.primary_key = :id
    clazz.class_eval(&block) if block_given?
    clazz.reset_column_information
    clazz
  end

  def destroy_test_models
    @test_models.reverse_each do |m|
      destroy_test_model(m)
    end
    @test_models.clear
  end

  def destroy_test_model(clazz)
    if Object.const_defined?(clazz.name)
      Object.send(:remove_const, clazz.name)
    end

    table_name = clazz.table_name
    if clazz.connection.data_source_exists?(table_name)
      clazz.connection.drop_table(table_name, force: :cascade)
    end

    if ActiveSupport::VERSION::MAJOR < 7
      ActiveSupport::Dependencies::Reference.clear!
    end
  end
end
