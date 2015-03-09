This is a pretty opinionated solution that we use internally. It's strictly designed to post to slack via the API and it uses our notion of wrapping EVERYTHING with a role. All of our plugins automatically use brain storage as well. To be able to execute anything with hubot, you have to be a `rundeck_admin` role user (per the `hubot-auth` plugin).

`HUBOT_RUNDECK_URL` should be set to the root URL of your Rundeck server, not
including the path to the current api version. 
**NOTE**: Currently relying on Rundeck API version 12.

You should be able to tease out the rundeck API stuff specifically.

It depends on a common format for your job defs in rundeck. We have two types of jobs in rundeck that we use via this plugin:

- ad-hoc
- predefined

ALL of our jobs have a common parameter called `slack_channel`. Hubot will automatically set this for you based on where/who it was talking to.

The ad-hoc jobs all have an option called `nodename`. When you call the job via hubot, you pass the nodename as the last option like so:

`hubot rundeck adhoc why-run dcm-logstash-01`

this would run chef in why-run mode on node `dcm-logstash-01`

We also have predefined jobs in rundeck that take no arguments. Those we simply run with:

`hubot rundeck run do-some-thing`

You can get the status of any job with:

`hubot rundeck output <jobid>`

This will post preformatted text to the slack api.

This was all largely written by Dan Ryan with a bit of tweaks from other team members.
