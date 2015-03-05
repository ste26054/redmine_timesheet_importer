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

  REQUIRED_ATTRS = [:id, :login, :update_date, :hours, :activity]
  OPTIONAL_ATTRS = [:comment, :notes]
  TIME_ENTRY_ISSUE_ATTRS = REQUIRED_ATTRS + OPTIONAL_ATTRS
  
  def index
    unless User.current.allowed_to?(:timesheet_import, nil, {:global => :true})
      render_403 and return
    end
  end

  class CsvFile
    attr_accessor :created, :filename, :csv_data
    def initialize
      @created = @filename = @csv_data = nil
    end
  end

  def merge_files_to_csv(files, options)
    quote_char = options[:wrapper]
    col_sep = options[:splitter]
    encoding = options[:encoding]

    # Read all binary files input in params[:files]
    # csv_files = []
    hdrs = []

    headers_in_file = false

    csv_final = CSV.generate({ :headers => true,
                                  :encoding => encoding,
                                  :quote_char => quote_char,
                                  :col_sep => col_sep,
                                  :skip_blanks => true
                                }) do |csv|
      files.each_with_index do |file, i|
        unless file.content_type == "text/csv" || file.content_type == "application/vnd.ms-excel"
          raise ArgumentError "Only CSV files are accepted. Detected: #{file.content_type}"
          return
        end
        # csv_file = CsvFile.new
        # csv_file.created = Time.new
        # csv_file.filename = file.original_filename
        #csv_files[i].csv_raw = file.read

        # Put each in new CSV object
        csv_data = CSV.new(file.read, { :headers => true,
                                  # :encoding => encoding,
                                  :quote_char => quote_char,
                                  :col_sep => col_sep,
                                  :skip_blanks => true
                                }).each_with_index do |row, j|

          if headers_in_file == false
            r = row.headers + ["File Name","File Line No"]
            csv << r
            headers_in_file = true
          end
          row["File Name"] = file.original_filename
          row["File Line No"] = j + 2
          csv << row

          hdrs[i] = row.headers
        end

        
        # Trick to detect non different array of headers
        unless hdrs.uniq.length == 1
          raise ArgumentError, "The files provided have different headers. Please provide files with exactly the same headers order & syntax to ensure a correct import"
          return
        end


      end

    end
    #END CSV LOOP


    # Return CSV embedded object
    out_csv = CsvFile.new
    out_csv.created = Time.new
    out_csv.csv_data = csv_final
    # out_csv.filename = csv_files.map { |r| r.filename }
    # out_csv.filename = out_csv.filename.join("; ")
    out_csv.filename = "merged_csv"
    return out_csv
  end

  def match
    iip = nil
    
    unless params[:retry]
      # Delete existing iip to ensure there can't be two iips for a user
      TimesheetImportInProgress.delete_all(["user_id = ?",User.current.id])
      # save import-in-progress data

      if params[:files] == nil
        flash[:error] = 'You must provide at least a file !'
        redirect_to timesheet_importer_index_path
        return
      end
        iip = TimesheetImportInProgress.new(:user_id => User.current.id)
        iip.quote_char = params[:wrapper]
        iip.col_sep = params[:splitter]
        iip.encoding = params[:encoding]

        begin
          processed_file = merge_files_to_csv(params[:files],{:wrapper => iip.quote_char,
                                                              :splitter => iip.col_sep,
                                                              :encoding => iip.encoding})
        rescue ArgumentError => e
          flash[:error] = e.message
          redirect_to timesheet_importer_index_path
          return
        end

        iip.created = processed_file.created
        iip.filename = processed_file.filename
        iip.csv_data = processed_file.csv_data
        iip.save
    else
      iip = TimesheetImportInProgress.find_by_user_id(User.current.id)
      if iip == nil
        flash[:error] = "No import is currently in progress"
        return
      end
    end

    @original_filename = iip.filename
    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")


    # display sample
    sample_count = 5
    i = 0
    @samples = []
    

      begin
        if iip.csv_data.lines.to_a.size <= 1
          flash[:error] = 'No data line in your CSV, check the encoding of the file<br/><br/>Header :<br/>'.html_safe +
            iip.csv_data
          redirect_to timesheet_importer_index_path
          return
        end

        CSV.new(iip.csv_data, { :headers => true,
                                :encoding => iip.encoding,
                                :quote_char => iip.quote_char,
                                :col_sep => iip.col_sep,
                                :skip_blanks => true
                              }
                               ).each do |row|
          #Deletes empty CSV lines not detected by the option :skip_blanks => true
          unless row.to_s.split(iip.col_sep).delete_if {|e| e == "" or e == "\n"} == [] 
            @samples[i] = row
            i += 1
            if i >= sample_count
              break
            end
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

        redirect_to timesheet_importer_index_path
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

      redirect_to timesheet_importer_index_path

      return
    end

    # fields
    @attrs = Array.new
  
    # Humanizes fields: e.g. update_date -> Update date
    #for each entry of attrs: [humanized symbol, :symbol]
    TIME_ENTRY_ISSUE_ATTRS.each do |attr|
      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
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
          logger.info "IN MATCH, IIP: #{iip}"
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
        

    @fields_map = {}

    params[:fields_map].each { |k, v| @fields_map[k.unpack('U*').pack('U*')] = v }
    

    # attrs_map is fields_map's invert
    attrs_map = @fields_map.invert

    # Convert string string hash keys to symbol
    attrs_map = Hash[attrs_map.map{ |k, v| [k.to_sym, v] }]

    attrs_cmp = REQUIRED_ATTRS - attrs_map.keys
    
    unless attrs_cmp.empty?
      flash[:error] = "The following columns are missing or not mapped properly: #{l_or_humanize(attrs_cmp, :prefix=>":")}"
      redirect_to timesheet_importer_match_path(:retry => true, :iip => iip)
      return
    end

    logger.info "ATTRS MAP IS: #{attrs_map}"
    @errs = Hash.new { |hash, key| hash[key] = {} }

    @tracker_non_productive = Tracker.find_by_name!("NonProductive")


    # BEGIN CSV ROW LOOP

    CSV.new(iip.csv_data, {:headers=>true,
                           :encoding=>iip.encoding,
                           :quote_char=>iip.quote_char,
                           :col_sep=>iip.col_sep,
                           :skip_blanks => true}).each_with_index do |row, index|
      
      unless row.to_s.split(iip.col_sep).delete_if {|e| e == "" or e == "\n"} == []

        @row_err = false

        attrs_map.each do |k, v|
          @col_err = false
          case k
          when :login
            begin
              @user = nil
              @user = User.find_by_login!(row[attrs_map[:login]])
            rescue ActiveRecord::RecordNotFound => e
              @col_err = true
            end
          when :id
            begin
              @issue = nil
              @issue = Issue.find_by_id!(row[attrs_map[:id]])
            rescue ActiveRecord::RecordNotFound => e
              @col_err = true
            end
          when :activity
            begin
              @time_entry_activity = nil
              @time_entry_activity = TimeEntryActivity.find_by_name!(row[attrs_map[:activity]])
            rescue ActiveRecord::RecordNotFound => e
              @col_err = true
            end
          when :update_date
            begin
              @date = nil
              @date = Date.parse(row[attrs_map[:update_date]])
            rescue  => e
              @col_err = true
            end
          when :hours
            begin
              @hours = nil
              @hours = row[attrs_map[:hours]].to_f
              if @hours < 0
                raise ArgumentError, "Hours cannot be negative"
              end
            rescue ArgumentError => e
              @col_err = true
            end
          else

          end

          if @col_err == true
            @row_err = true
            if e != nil
              @messages << "Partial error row #{index + 2}, column #{attrs_map[k]}: #{e.message}"
            else
              @messages << "Partial error row #{index + 2}, column #{attrs_map[k]}: unknown error"
            end
            @errs[k][index] = true
            
          end

        end #END ATTRS MAP CHECK
        

        if @row_err == true
          @failed_count += 1
          @failed_issues[index] = row
        else
          begin
            project = Project.find_by_id!(@issue.project_id)
            @affect_projects_issues.has_key?(project.name) ? @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1
          rescue ActiveRecord::RecordNotFound => e
            @messages << "General error row #{index + 2}: #{e.message}"
            @failed_count += 1
            @failed_issues[index] = row
          end
          begin
            #logger.info "#{index}: ISSUE ID: #{issue.id}. User: #{user} User ID: #{user.id}. ID Assigned to: #{issue.assigned_to_id}."
            #if user.member_of?(issue.project) || user.admin?
            #  logger.info "#{index} USER HAS RIGHTS TO UPDATE ISSUE"
            #else
            #  logger.info "#{index} USER IS NOT ALLOWED TO UPDATE ISSUE"
            #end
            unless @issue.watched_by?(@user) || @user.id == @issue.assigned_to_id || (@tracker_non_productive.id == @issue.tracker.id && @user.member_of?(@issue.project))
              unless @tracker_non_productive.id == @issue.tracker.id && row[attrs_map[:hours]] == nil
                @errs[:login][index] = true
                @errs[:id][index] = true
                raise ArgumentError, "User #{@user} is not allowed to log time on issue #{@issue}"
              end
            else
              unless @tracker_non_productive.id == @issue.tracker.id && row[attrs_map[:hours]] == nil
                @time_entry = TimeEntry.new(:issue_id => @issue.id, 
                                              :spent_on => @date,
                                              :activity => @time_entry_activity,
                                              :hours => row[attrs_map[:hours]],
                                              :comments => row[attrs_map[:comment]], 
                                              :user => @user)

                journal = Journal.new(:journalized => @issue,
                                      :user => @user,
                                      :notes => row[attrs_map[:notes]],
                                      :created_on => @date)

                @time_entry.save!
                journal.save!
              end

            end
            #if user.allowed_to?(:edit_issues, issue.project)
            #  logger.info "#{index} USER ALLOWED TO EDIT ISSUE"
            #end
           rescue ArgumentError => e
              @failed_count += 1
              @failed_issues[index] = row
              @messages << "General error row #{index + 2}: #{e.message}"
           rescue => e
             @messages << "General error row #{index + 2}: #{e.message}"
             @failed_count += 1
             @failed_issues[index] = row
          else
            unless @tracker_non_productive.id == @issue.tracker.id && row[attrs_map[:hours]] == nil
              @time_entry_ids.push(@time_entry.id)
              @handle_count += 1
            end
          end
        end
      end
    end 
    #END CSV ROW LOOP
    
    if @failed_issues.size > 0
      @handle_count = 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers

      @time_entry_ids.each do |entry_id|
        entry = TimeEntry.find_by_id(entry_id)
        unless entry.delete
          logger.info "Timesheet import Error: Time entry #{entry_id} could not be deleted."
        end
      end
    else
     # Clean up after ourselves
    iip.delete
    
    # Garbage prevention: clean up iips older than 3 days
    TimesheetImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])     

    end
    

  end

private


  def flash_message(type, text)
    flash[type] ||= ""
    flash[type] += "#{text}<br/>"
  end

  

  
end
