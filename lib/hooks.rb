module RedmineTimesheetImporter
	class ViewHookListener < Redmine::Hook::ViewListener
		render_on(:view_attachments_form, :partial => 'attachments/form')
	end
end