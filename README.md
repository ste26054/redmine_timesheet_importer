= Redmine Timesheet Importer (CSV)

This plugin is mostly based on https://github.com/leovitch/redmine_importer. I have removed the issue creation feature, the plugin appears on the top menu as it is no longer project-limited.

DB migration is required for this plugin

Allows administrators to import CSV formated timesheets

Here are the headers required (a mapping is possible if the column names are different):

| HEADER | id | user_login | update_date | hours | comment | activity | notes |
|----------|:--------:|:---------------------------------------:|:---------------------------------------------:|:--------------------------------:|:-------------------------:|:-------------:|:--------------------------------------:|
| COMMENTS | Issue ID | Login name who logged time on the issue | Date when the user has created the time entry | Hours logged for this time entry | Comment on the Time Entry | Activity type | Notes which will appear in the history |
| REQUIRED | * | * | * | * |  | * |  |
|  |  |  |  |  |  |  |  |