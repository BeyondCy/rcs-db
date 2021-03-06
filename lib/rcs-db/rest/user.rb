#
# Controller for the User objects
#

require 'digest/sha1'

module RCS
module DB

class UserController < RESTController

  def index
    require_auth_level :admin
    require_auth_level :admin_users

    users = User.all.map do |user|
      user[:password_expired] = !!user.password_expired?

      # Prevent these attributes to reach the client
      user[:pass]             = nil
      user[:pwd_changed_at]   = nil
      user[:pwd_changed_cs]   = nil
      user
    end

    return ok(users)
  end

  def show
    require_auth_level :admin, :tech, :view

    # we need to leave access to themselves for everyone
    return not_found('User not found') if !admin? && @params['_id'] != @session.user[:_id].to_s

    mongoid_query do
      user = User.find(@params['_id'])
      return ok(user)
    end
  end
  
  def create
    require_auth_level :admin
    require_auth_level :admin_users

    return conflict('LICENSE_LIMIT_REACHED') unless LicenseManager.instance.check :users

    user = User.new

    user.name     = @params['name']
    user.pass     = @params['pass']
    user.desc     = @params['desc']
    user.contact  = @params['contact']
    user.privs    = @params['privs']
    user.enabled  = @params['enabled']
    user.locale   = @params['locale']
    user.timezone = @params['timezone']

    user.save

    user.errors.each do |attribute, message|
      return conflict(message)
    end

    if @params.has_key? 'group_ids'
      @params['group_ids'].each do |gid|
        group = ::Group.find(gid)
        group.users << user
      end
    end

    username = @params['name']
    Audit.log :actor => @session.user[:name], :action => 'user.create', :user_name => username, :desc => "Created the user '#{username}'"

    return ok(user)
  end

  def update
    require_auth_level :admin, :sys, :tech, :view

    mongoid_query do
      user = User.find(@params['_id'])
      @params.delete('_id')

      # if non-admin you can modify only yourself
      unless @session[:level].include? :admin
        return not_found("User not found") if user._id != @session.user[:_id]
      end

      # if enabling a user, check the license
      if user.enabled == false and @params.include?('enabled') and @params['enabled'] == true
        return conflict('LICENSE_LIMIT_REACHED') unless LicenseManager.instance.check :users
      end

      if @params['pass'] and user.has_password?(@params['pass'])
        return conflict("SAME_PASSWORD")
      end

      result = user.update_attributes(@params)

      user.errors.each do |attribute, message|
        return conflict(message)
      end

      # if pass is modified, treat it separately
      if @params.has_key? 'pass'
        Audit.log :actor => @session.user[:name], :action => 'user.update', :user_name => user['name'], :desc => "Changed password for user '#{user['name']}'"
      else
        @params.each_pair do |key, value|
          if key == 'dashboard_ids'
            value.collect! {|x| Moped::BSON::ObjectId(x)}
          end
          if user[key.to_s] != value and not key['_ids']
            Audit.log :actor => @session.user[:name], :action => 'user.update', :user_name => user['name'], :desc => "Updated '#{key}' to '#{value}' for user '#{user['name']}'"
          end
        end
      end

      ok(user)
    end
  end

  def add_recent
    require_auth_level :admin, :sys, :tech, :view

    mongoid_query do
      section, type = @params['section'], @params['type']

      if (section == 'operations') or (section == 'intelligence' and type == 'operation')
        item = ::Item.find(@params['id'])
        kind = item._kind
        Audit.log :actor => @session.user[:name], :action => "#{kind}.view", :_item => item, :desc => "Has accessed the #{kind}: #{item.name}"

        @session.user.add_recent(section: section, type: kind, id: item.id)
      elsif (section == 'intelligence' and type == 'entity')
        entity = ::Entity.find(@params['id'])
        Audit.log :actor => @session.user[:name], :action => 'entity.view', :_entity => entity, :desc => "Has accessed the entity: #{entity.name}"

        @session.user.add_recent(section: section, type: type, id: entity.id)
      end

      ok(@session.user)
    end
  end

  def destroy
    require_auth_level :admin
    require_auth_level :admin_users

    mongoid_query do
      user = User.find(@params['_id'])
      
      Audit.log :actor => @session.user[:name], :action => 'user.destroy', :user_name => @params['name'], :desc => "Deleted the user '#{user['name']}'"
      
      user.destroy
      
      return ok
    end
  end

  def message
    require_auth_level :admin
    require_auth_level :admin_users

    mongoid_query do
      if @params['_id'].nil?
        PushManager.instance.notify('message', {from: @session.user[:name], text: @params['text']})
      else
        user = User.find(@params['_id'])
        PushManager.instance.notify('message', {from: @session.user[:name], rcpt: user[:_id], text: @params['text']})
      end

      return ok
    end
  end

end

end #DB::
end #RCS::