require 'csv'
require 'tempfile'

class MultipleIssuesForUniqueValue < Exception
end

class NoIssueForUniqueValue < Exception
end

Journal.class_exec do
  def empty?
    (details.empty? && notes.blank?)
  end
end

class TimesheetImporterController < ApplicationController
  unloadable
  
  #before_filter :find_project
##
#  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
#    :author, :description, :category, :priority, :tracker, :status,
#    :start_date, :due_date, :done_ratio, :estimated_hours,
#    :parent_issue, :watchers ]

  TIME_ENTRY_ISSUE_ATTRS = [:id, :user_login, :update_date, :hours, :comment, :activity, :notes, :project]
  
  def index
  end

  def match
    #NEW COMMENT
    # Delete existing iip to ensure there can't be two iips for a user
    TimesheetImportInProgress.delete_all(["user_id = ?",User.current.id])
    # save import-in-progress data
    iip = TimesheetImportInProgress.find_or_create_by_user_id(User.current.id)
    iip.quote_char = params[:wrapper]
    iip.col_sep = params[:splitter]
    iip.encoding = params[:encoding]
    iip.created = Time.new

    unless params[:file]
      flash[:error] = 'You must provide a file !'

      redirect_to importer_index_path
      return
    end

    iip.csv_data = params[:file].read
    iip.save
    
    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")
    @original_filename = params[:file].original_filename
    
    # display sample
    sample_count = 5
    i = 0
    @samples = []
    
    begin
      if iip.csv_data.lines.to_a.size <= 1
        flash[:error] = 'No data line in your CSV, check the encoding of the file<br/><br/>Header :<br/>'.html_safe +
          iip.csv_data

        redirect_to importer_index_path

        return
      end

      CSV.new(iip.csv_data, {:headers=>true,
                            :encoding=>iip.encoding,
                             :quote_char=>iip.quote_char,
                             :col_sep=>iip.col_sep}).each do |row|
        @samples[i] = row
        i += 1
        if i >= sample_count
          break
        end
      end # do
    rescue Exception => e
      csv_data_lines = iip.csv_data.lines.to_a

      error_message = e.message +
        '<br/><br/>Header :<br/>'.html_safe +
        csv_data_lines[0]

      if csv_data_lines.size > 0
        error_message += '<br/><br/>Error on header or line :<br/>'.html_safe +
          csv_data_lines[@samples.size + 1]
      end

      flash[:error] = error_message

      redirect_to importer_index_path

      return
    end

    if @samples.size > 0
      @headers = @samples[0].headers
    end
    
    missing_header_columns = ''
    @headers.each_with_index{|h, i|
      if h.nil?
        missing_header_columns += " #{i+1}"
      end
    }

    if missing_header_columns.present?
      flash[:error] = 'Column header missing : ' + missing_header_columns + " / #{@headers.size}" +
        '<br/><br/>Header :<br/>'.html_safe +
        iip.csv_data.lines.to_a[0]

      redirect_to importer_index_path

      return
    end

    # fields
    @attrs = Array.new
  
    TIME_ENTRY_ISSUE_ATTRS.each do |attr|
      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
    end

    @attrs.sort!
  end
  
  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value, row_data)
    if @issue_by_unique_attr.has_key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end

    if unique_attr == "id"
      issues = [Issue.find_by_id(attr_value)]
    else
      # Use IssueQuery class Redmine >= 2.3.0
      begin
        if Module.const_get('IssueQuery') && IssueQuery.is_a?(Class)
          query_class = IssueQuery
        end
      rescue NameError
        query_class = Query
      end

      query = query_class.new(:name => "_importer", :project => @project)
      query.add_filter("status_id", "*", [1])
      query.add_filter(unique_attr, "=", [attr_value])
      
      issues = Issue.find :all, :conditions => query.statement, :limit => 2, :include => [ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]
    end
    
    if issues.size > 1
      @failed_count += 1
      @failed_issues[@failed_count] = row_data
      @messages << "Warning: Unique field #{unique_attr} with value '#{attr_value}' in issue #{@failed_count} has duplicate record"
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr} with value '#{attr_value}' has duplicate record"
      else
      if issues.size == 0
        raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
      end
      issues.first
    end
  end

  # Returns the id for the given user or raises RecordNotFound
  # Implements a cache of users based on login name
  def user_for_login!(login)
    begin
      if !@user_by_login.has_key?(login)
        @user_by_login[login] = User.find_by_login!(login)
      end
    rescue ActiveRecord::RecordNotFound
      if params[:use_anonymous]
        @user_by_login[login] = User.anonymous()
      else
        @unfound_class = "User"
        @unfound_key = login
        raise
      end
    end
    @user_by_login[login]
  end

  def user_id_for_login!(login)
    user = user_for_login!(login)
    user ? user.id : nil
  end


  def to_boolean(str)
      str == 'true'
  end
    
  
  def result
    @time_entry_ids = []
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = Hash.new
    @messages = Array.new
    @affect_projects_issues = Hash.new
    # This is a cache of previously inserted issues indexed by the value
    # the user provided in the unique column
    @issue_by_unique_attr = Hash.new
    # Cache of user id by login
    @user_by_login = Hash.new
    # Cache of Version by name
    @version_id_by_name = Hash.new
    
    # Retrieve saved import data
    iip = TimesheetImportInProgress.find_by_user_id(User.current.id)
    if iip == nil
      flash[:error] = "No import is currently in progress"
      return
    end
    if iip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = "You seem to have started another import " \
          "since starting this one. " \
          "This import cannot be completed"
      return
    end
    

    fields_map = {}
    params[:fields_map].each { |k, v| fields_map[k.unpack('U*').pack('U*')] = v }
    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert


    # BEGIN CSV ROW LOOP

    CSV.new(iip.csv_data, {:headers=>true,
                           :encoding=>iip.encoding,
                           :quote_char=>iip.quote_char,
                           :col_sep=>iip.col_sep}).each_with_index do |row, index|


      

        #TODO: check if issue id exists
        begin
          issue = Issue.find_by_id!(row[attrs_map["id"]])
          project = Project.find_by_id!(issue.project_id)

          @affect_projects_issues.has_key?(project.name) ?
          @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1


          time_entry = TimeEntry.new(:issue_id => issue.id, 
                                    :spent_on => Date.parse(row[attrs_map["update_date"]]),
                                    :activity => TimeEntryActivity.find_by_name(row[attrs_map["activity"]]),
                                    :hours => row[attrs_map["hours"]],
                                    :comments => row[attrs_map["comment"]], 
                                    :user => User.find_by_login(row[attrs_map["user_login"]]))
          time_entry.save!

          @time_entry_ids.push(time_entry.id)
          @handle_count += 1
        rescue
          @failed_count += 1
          @failed_issues[index] = row
          @messages << "Warning: The following data-validation errors occurred on time_entry #{@failed_count} in the list below"
          
          if time_entry != nil
            time_entry.errors.each do |attr, error_message|
              @messages << "Error: #{attr} #{error_message}"
            end
          end
          next
        end
        #unless time_entry.save
          

        #else

        #end
     
    end 
    #END CSV ROW LOOP
    
    if @failed_issues.size > 0
      @handle_count = 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers

      @time_entry_ids.each do |entry_id|
        entry = TimeEntry.find_by_id(entry_id)
        unless entry.delete
          @messages << "Error: Time entry #{entry_id} could not be deleted."
        end
      end

      @messages << "Warning: The Timesheet was not imported due to errors. Please correct them and try again"
    end
    
    # Clean up after ourselves
    iip.delete
    
    # Garbage prevention: clean up iips older than 3 days
    TimesheetImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])
  end

private


  def flash_message(type, text)
    flash[type] ||= ""
    flash[type] += "#{text}<br/>"
  end

  
end
