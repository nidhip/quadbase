# Copyright 2011-2012 Rice University. Licensed under the Affero General Public 
# License version 3 or later.  See the COPYRIGHT file for details.

class UsersController < AdminController
  skip_before_filter :authenticate_admin!, :only => [:show, :help, :search]
  skip_before_filter :authenticate_user!, :only => [:help]
  before_filter {select_tab(:account)}
  
  def index
    @users = User.all
  end

  def show
    respond_with(@user = User.find(params[:id]))
  end
  
  def edit
    respond_with(@user = User.find(params[:id]))
  end
  
  def update
    @user = User.find(params[:id])

    @user.is_administrator = params[:user][:is_administrator]
    if params[:user][:disable].blank?
      @user.enable!
    else
      @user.disable!
    end
    respond_with(@user)
  end

  def help
  end

  def search
    @selected_type = params[:selected_type]
    @text_query = params[:text_query]
    @users = User.search(@selected_type, @text_query)
    @can_add = Hash.new
    @add_path = params[:add_path]
    @container_type = params[:container_type]
    @container_id = params[:container_id]
    @add_label = params[:add_label] || 'Add user'
    @cannot_add_label = params[:cannot_add_label] || 'Cannot add user'
    respond_to do |format|
      format.html
      format.js
    end
  end
  
end
