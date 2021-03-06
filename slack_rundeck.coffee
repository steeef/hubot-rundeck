# Description
#   Rundeck integration with hubot
#
# Dependencies:
#   "underscore": "^1.6.0"
#   "strftime": "^0.8.0"
#   "xml2js": "^0.4.1"
#   "hubot-auth"
#
# Configuration:
#   HUBOT_RUNDECK_URL - root URL for Rundeck, not including api path
#   HUBOT_RUNDECK_TOKEN
#   HUBOT_RUNDECK_PROJECT
#
# Commands:
#   hubot (rd|rundeck) (list|jobs) - List all Rundeck jobs
#   hubot (rd|rundeck) show <name> - Show detailed info for the job <name>
#   hubot (rd|rundeck) run <name> - Execute a Rundeck job <name>
#   hubot (rd|rundeck) (adhoc|ad-hoc|ad hoc) <name> <nodename> - Execute an ad-hoc Rundeck job <name> on node <nodename>
#   hubot (rd|rundeck) output <id> - Print the output of execution <id>
#
# Notes:
#   REQUIRES Rundeck API version 12
#   Todo:
#     * make job name lookups case-insensitive
#     * ability to show results of a job/execution
#     * query job statistics
#
# Author:
#   <dan.ryan@XXXXXXXXXX>

_ = require('underscore')
sys = require 'sys' # Used for debugging
querystring = require 'querystring'
url = require 'url'
inspect = require('util').inspect
strftime = require('strftime')
Parser = require('xml2js').Parser

class Rundeck
  constructor: (@robot) ->
    @logger = @robot.logger

    @baseUrl = process.env.HUBOT_RUNDECK_URL
    @apiUrl = "#{process.env.HUBOT_RUNDECK_URL}/api/12"
    @authToken = process.env.HUBOT_RUNDECK_TOKEN
    @project = process.env.HUBOT_RUNDECK_PROJECT
    @room = process.env.HUBOT_RUNDECK_ROOM
    @adminRole = "rundeck_admin"

    @headers =
      "Accept": "application/xml"
      "Content-Type": "application/xml"
      "X-Rundeck-Auth-Token": "#{@authToken}"

    @plainTextHeaders =
      "Accept": "text/plain"
      "Content-Type": "text/plain"
      "X-Rundeck-Auth-Token": "#{@authToken}"

    @cache = {}
    @cache['jobs'] = {}
    @brain = @robot.brain.data

    robot.brain.on 'loaded', =>
      @logger.info("Loading rundeck jobs from brain")
      if @brain.rundeck?
        @logger.info("Loaded saved rundeck jobs")
        @cache = @brain.rundeck
      else
        @logger.info("No saved rundeck jobs found ")
        @brain.rundeck = @cache

  cache: -> @cache
  parser: -> new Parser()
  jobs: -> new Jobs(@)

  save: ->
    @logger.info("Saving cached rundeck jobs to brain")
    @brain.rundeck = @cache

  getOutput: (url, cb) ->
    @robot.http("#{@apiUrl}/#{url}").headers(@plainTextHeaders).get() (err, res, body) =>
      if err?
        @logger.err JSON.stringify(err)
      else
        cb body

  get: (url, cb) ->
    parser = new Parser()

    @robot.http("#{@apiUrl}/#{url}").headers(@headers).get() (err, res, body) =>
      if err?
        @logger.error JSON.stringify(err)
      else
        @logger.debug body
        parser.parseString body, (e, result) ->
          cb result

class Job
  constructor: (data) ->
    @id = data["$"].id
    @name = data.name[0]
    @description = data.description[0]
    @group = data.group[0]
    @project = data.project[0]

  format: ->
    "Name: #{@name}\nId: #{@id}\nDescription: #{@description}\nGroup: #{@group}\nProject: #{@project}"

  formatList: ->
    "#{@name} - #{@description}"

class Jobs
  constructor: (@rundeck) ->
    @logger = @rundeck.logger

  list: (cb) ->
    jobs = []
    @rundeck.get "project/#{@rundeck.project}/jobs", (results) ->
      for job in results.jobs.job
        jobs.push new Job(job)

      cb jobs

  find: (name, cb) ->
    @list (jobs) =>
      job = _.findWhere jobs, { name: name }
      if job
        cb job
      else
        cb false

  run: (name, query, cb) ->
    @find name, (job) =>
      if job
        uri = "job/#{job.id}/run"
        uri += query if query?
        @rundeck.get uri, (results) ->
          cb job, results
      else
        cb null, false

module.exports = (robot) ->
  logger = robot.logger
  rundeck = new Rundeck(robot)

  # hubot rundeck list
  robot.respond /(?:rd|rundeck) (?:list|jobs)$/i, (msg) ->
    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().list (jobs) ->
        if jobs.length > 0
          for job in jobs
            msg.send job.formatList()
        else
          msg.send "No Rundeck jobs found."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # hubot rundeck output <job-id>
  # sample url: 
  robot.respond /(?:rd|rundeck) output (.+)/i, (msg) ->
    jobid = msg.match[1].trim()

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.getOutput "execution/#{jobid}/output", (output) ->
        if output
          msg.send "```#{output}```"
        else
          msg.send "Could not find output for Rundeck job \"#{jobid}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # hubot rundeck show <name>
  robot.respond /(?:rd|rundeck) show ([\w -_]+)/i, (msg) ->
    name = msg.match[1].trim()

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().find name, (job) ->
        if job
          msg.send job.format()
        else
          msg.send "Could not find Rundeck job \"#{name}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # hubot rundeck run <name>
  robot.respond /(?:rd|rundeck) run ([\w -_]+)/i, (msg) ->
    name = msg.match[1].trim()

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().run name, null, (job, results) ->
        if job
          robot.logger.debug inspect(results, false, null)
          msg.send "Running job #{name}: #{results.executions.execution[0]['$'].href}"
        else
          msg.send "Could not execute Rundeck job \"#{name}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # takes all but last word as the name of our job
  # hubot rundeck ad-hoc <name> <nodename>
  robot.respond /(?:rd|rundeck) (?:ad[ -]?hoc) ([\w -_]+) ([\w-]+)/i, (msg) ->
    name = msg.match[1].trim()
    params = { argString: "-nodename #{msg.match[2].trim().toLowerCase()}" }
    query = "?#{querystring.stringify(params)}"

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().run name, query, (job, results) ->
        if job
          msg.send "Running job #{name}: #{results.executions.execution[0]['$'].href}"
        else
          msg.send "Could not execute Rundeck job \"#{name}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # allows webhook from Rundeck for job notifications
  # It would be great to get the information from the body of the request, but
  # unfortunately, Rundeck's built-in webhooks only use XML, and Hubot's
  # Express router expects JSON. So we'll grab from the URI params.
  # expects:
  # http://hubot:port/hubot/rundeck-webhook/roomname/?status=${execution.status}&job=${job.name}&execution_id=${execution.id}
  robot.router.post "/hubot/rundeck-webhook/:room", (req, res) ->
    query = querystring.parse(url.parse(req.url).query)
    status = query.status
    job = query.job
    execution_id = query.execution_id
    robot.messageRoom req.params.room, ":rundeck: Rundeck: #{job} ##{execution_id} - *#{status}*: #{rundeck.baseUrl}/project/#{rundeck.project}/execution/show/#{execution_id}"
    res.end "ok"
