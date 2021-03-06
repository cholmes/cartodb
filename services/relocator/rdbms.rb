# encoding: utf-8
require 'sequel'

module CartoDB
  module Relocator
    class RDBMS
      def initialize(connection)
        @connection = connection
        @connection.extension :pg_array
      end #initialize

      def rename_user(existing_username, new_username)
        connection.run("
          ALTER USER #{existing_username}
          RENAME TO #{new_username}
        ")
      end #rename_user

      def create_user(username, password)
        connection.run("
          CREATE USER #{username} PASSWORD '#{password}'
        ")
      end #create_user

      def set_password(username, password)
        connection.run("
          ALTER USER #{username} PASSWORD '#{password}'
        ")
      end #set_password

      def create_database(database_name, owner)
        connection.run("
          CREATE DATABASE     #{database_name}
          WITH TEMPLATE     = template_postgis
          OWNER             = #{owner}
          ENCODING          = 'UTF8'
          CONNECTION LIMIT  = -1
        ")
      end #create_database

      def export_layers_maps_for(user_id)
        connection.execute("
          SELECT DISTINCT layer_id, map_id 
          FROM layers_maps, maps 
          WHERE layers_maps.map_id in (
            SELECT id 
            FROM maps
            WHERE user_id = #{user_id}
          )
        ", &:to_a)
      end #export_layers_maps_for

      def export_user(user_id)
        connection.execute("
          SELECT  * 
          FROM    users
          WHERE   id = #{user_id}
        ", &:to_a)
      end #export_user

      def export_layers_for(user_id)
        exported_layers = connection.execute("
          SELECT  * 
          FROM    layers 
          WHERE   id in (
                    SELECT  layer_id 
                    FROM    layers_maps, maps 
                    WHERE   maps.user_id = #{user_id}
                  )
        ", &:to_a)

        exported_layers.concat(
          connection.execute(%Q{
            SELECT *
            FROM layers
            WHERE id in(
              SELECT layer_id
              FROM layers_users
              WHERE layers_users.user_id = #{user_id}
            )
          }, &:to_a)
        )
        
        exported_layers.uniq
      end #export_layers_for

      def export_records_for(user_id, table)
        connection.execute("
          SELECT *  FROM #{table}
          WHERE     user_id = #{user_id}
        ", &:to_a)
      end #export_records_for

      def export_visualizations_for(user_id)
        map_ids = connection[:maps].select(:id)
                  .where(user_id: user_id)
                  .map { |record| record.fetch(:id) }
        connection[:visualizations].where(map_id: map_ids).to_a
      end #export_visualizations_for

      def export_overlays_for(visualization_ids)
        connection[:overlays].where(visualization_id: visualization_ids).to_a
      end #export_overlays_for

      def export_layers_user_tables_for(user_id)
        connection.execute(%Q{
          SELECT  layers_user_tables.id,
                  layers_user_tables.layer_id,
                  layers_user_tables.user_table_id
          FROM    user_tables, layers_user_tables
          WHERE   user_tables.user_id = #{user_id}
          AND     user_tables.id = layers_user_tables.user_table_id
        }, &:to_a)
      end #export_layers_user_tables

      def insert_in(table_name, records=[], user=nil)
        map = {}
        records.each do |record| 
          old_id = record.delete('id')
          raise 'No old id' unless old_id
          record.store('user_id', user.id) if record.has_key?('user_id')
          new_id = connection[table_name.to_sym].insert(record)
          map.store(old_id.to_s, new_id.to_s)
        end
        map
      end #insert_in

      def insert_oauth_tokens_for(arguments)
        records   = arguments.fetch(:records)
        map       = arguments.fetch(:client_applications_map)
        user      = arguments.fetch(:user)

        records.each do |record|
          old_id  = record.fetch('client_application_id').to_s
          record.delete('id')
          record.store('user_id', user.id)
          record.store('client_application_id', map.fetch(old_id))
          begin
            connection[:oauth_tokens].insert(record)
          rescue => exception
            return if exception.message =~ /violates unique constraint/
            raise exception
          end
        end
      end #insert_oauth_tokens_for

      def insert_client_applications_for(arguments)
        records   = arguments.fetch(:records)
        user      = arguments.fetch(:user, nil)
        renaming  = arguments.fetch(:renaming, false)
        map       = {}

        records.each do |record|
          old_id = record.delete('id')
          record.store('user_id', user.id)
          record['key'] = record['key'] + ":#{Time.now.to_i}" if renaming
          new_id = connection[:client_applications].insert(record)
          map.store(old_id.to_s, new_id.to_s)
        end
        map
      end #insert_client_applications_for

      def insert_layers_for(arguments)
        records = arguments.fetch(:records)
        user    = arguments.fetch(:user)
        map     = {}
        records.each do |record|
          old_id = record.delete('id')

          if record['options']
            regex           = %r{\"user_name\":\"\w+\"}
            replacement     = %Q{\"user_name\":\"#{user.username}\"}
            record['options']  = record['options'].gsub(regex, replacement)
          end
          new_id = connection[:layers].insert(record)
          map.store(old_id.to_s, new_id.to_s)
        end
        map 
      end #insert_layers_for

      def insert_layers_maps_for(arguments)
        records     = arguments.fetch(:records)
        layers_map  = arguments.fetch(:layers_map)
        maps_map    = arguments.fetch(:maps_map)

        records.each do |record| 
          old_layer_id  = record.fetch('layer_id').to_s
          old_map_id    = record.fetch('map_id').to_s
          record.delete('id')

          record.store('layer_id', layers_map.fetch(old_layer_id))
          record.store('map_id', maps_map.fetch(old_map_id))
          connection[:layers_maps].insert(record)
        end
      end #insert_layers_maps_for

      def insert_layers_users_for(arguments)
        records     = arguments.fetch(:records)
        layers_map  = arguments.fetch(:layers_map)
        user        = arguments.fetch(:user)

        records.each do |record| 
          old_layer_id  = record.fetch('layer_id').to_s
          record.delete('id')

          record.store('layer_id', layers_map.fetch(old_layer_id))
          record.store('user_id', user.id)
          connection[:layers_users].insert(record)
        end
      end #insert_layers_users_for

      def insert_user_tables_for(arguments)
        records           = arguments.fetch(:records)
        maps_map          = arguments.fetch(:maps_map)
        #data_imports_map  = arguments.fetch(:data_imports_map)
        user              = arguments.fetch(:user)
        database_name     = arguments.fetch(:database_name)
        map               = {}

        records.each do |record|
          old_map_id          = record.fetch('map_id').to_s
          #old_data_import_id  = record.fetch('data_import_id').to_s
          table_id            = table_id_for(user, record.fetch('name'))

          old_id = record.delete('id')
          record.store('user_id', user.id)
          record.store('map_id', maps_map.fetch(old_map_id))
          record.store('table_id', table_id)
          record.store('database_name', database_name)
          record.store('privacy', record.fetch('privacy').to_i)

          #if old_data_import_id
          #  record.store('data_import_id', data_imports_map.fetch(old_data_import_id))
          #end
          new_id = connection[:user_tables].insert(record)
          #connection[:data_imports].filter(id: record.fetch('data_import_id'))
          #  .update(table_id: new_id)
            
          map.store(old_id.to_s, new_id.to_s)
        end
        map
      end #insert_users_tables_for

      def insert_tags_for(arguments)
        user              = arguments.fetch(:user)
        records           = arguments.fetch(:records)
        tables_map        = arguments.fetch(:tables_map)

        records.each do |record|
          old_table_id = record.fetch('table_id')
          record.store('user_id', user.id)
          record.store('table_id', tables_map.fetch(old_table_id))
          record.delete('id')
          connection[:tags].insert(record)
        end
      end #insert_tags_for

      def insert_visualizations_for(arguments)
        records   = arguments.fetch(:records)
        maps_map  = arguments.fetch(:maps_map)

        records.each do |record|
          old_map_id = record.fetch('map_id').to_s
          record.store('map_id', maps_map.fetch(old_map_id))
          connection[:visualizations].insert(serialize_for_postgres(record))
        end
      end #insert_visualizations_for

      def serialize_for_postgres(record)
        Hash[
          record.map { |key, value|
            value = value.pg_array if value.is_a?(Array) && !value.empty? 
            [key, value]
          }
        ]
      end #serialize_for_postgres

      def insert_overlays_for(arguments)
        arguments.fetch(:records).each do |record|
          connection[:overlays].insert(record)
        end
      end #insert_overlays_for

      def insert_layers_user_tables_for(arguments)
        records     = arguments.fetch(:records)
        layers_map  = arguments.fetch(:layers_map)
        tables_map  = arguments.fetch(:tables_map)

        arguments.fetch(:records).each do |record|
          old_layer_id = record.fetch('layer_id').to_s
          old_table_id = record.fetch('user_table_id').to_s

          record.store('layer_id', layers_map.fetch(old_layer_id))
          record.store('user_table_id', tables_map.fetch(old_table_id))
          record.delete('id')

          connection[:layers_user_tables].insert(record)
        end
      end #insert_layers_user_tables_for

      def table_id_for(user, table_name)
        user.in_database
          .select(:pg_class__oid)
          .from(:pg_class)
          .join_table(:inner, :pg_namespace, oid: :relnamespace)
          .where(relkind: 'r', nspname: 'public', relname: table_name)
          .first[:oid]
      end #table_id_for

      private

      attr_accessor :connection
    end # RDBMS
  end # Relocator
end # CartoDB

