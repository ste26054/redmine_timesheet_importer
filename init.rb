# encoding: UTF-8

require 'redmine'

Redmine::Plugin.register :redmine_timesheet_importer do
  name 'Redmine Timesheet Importer'
  author 'Stephane EVRARD'
  description 'Plugin for importing CSV formatted TimeSheets. Based on the Issue import plugin for Redmine by Martin Liu / Leo Hourvitz / Stoyan Zhekov / Jérôme Bataille'
  version '0.1'

  #project_module :importer do
  #  permission :import, :importer => :index
  #end
  menu :top_menu, :importer, { :controller => 'importer', :action => 'index' }, :caption => :label_import, :before => :settings, :param => :project_id,
  :if => Proc.new { User.current.admin? }
end
