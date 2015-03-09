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
#   HUBOT_RUNDECK_URL
#   HUBOT_RUNDECK_TOKEN
#   HUBOT_RUNDECK_PROJECT
#
# Commands:
#   hubot rundeck (list|jobs) - List all Rundeck jobs
#   hubot rundeck show <name> - Show detailed info for the job <name>
#   hubot rundeck run <name> - Execute a Rundeck job <name>
#   hubot rundeck (adhoc|ad-hoc|ad hoc) <name> <nodename> - Execute an ad-hoc Rundeck job <name> on node <nodename>
#   hubot rundeck output <id> - Print the output of execution <id>
#
# Notes:
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
    @authToken = process.env.HUBOT_RUNDECK_TOKEN
    @project = process.env.HUBOT_RUNDECK_PROJECT
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
    @logger = @robot.logger
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
    @robot.http("#{@baseUrl}/#{url}").headers(@plainTextHeaders).get() (err, res, body) =>
      if err?
        @logger.err JSON.stringify(err)
      else
        cb body

  get: (url, cb) ->
    parser = new Parser()

    @robot.http("#{@baseUrl}/#{url}").headers(@headers).get() (err, res, body) =>
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
  robot.respond /rundeck (?:list|jobs)$/i, (msg) ->
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
  robot.respond /rundeck output (.+)/i, (msg) ->
    jobid = msg.match[1]

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.getOutput "execution/#{jobid}/output", (output) ->
        if output
          msg.send "```#{output}```"
        else
          msg.send "Could not find output for Rundeck job \"#{jobid}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # hubot rundeck show <name>
  robot.respond /rundeck show ([\w -_]+)/i, (msg) ->
    name = msg.match[1]

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().find name, (job) ->
        if job
          msg.send job.format()
        else
          msg.send "Could not find Rundeck job \"#{name}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # hubot rundeck run <name>
  robot.respond /rundeck run ([\w -_]+)/i, (msg) ->
    name = msg.match[1]

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().run name, null, (job, results) ->
        if job
          robot.logger.debug inspect(results, false, null)
          msg.send "Running job #{name}: #{results.result.executions[0].execution[0]['$'].href}"
        else
          msg.send "Could not execute Rundeck job \"#{name}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."

  # takes all but last word as the name of our job
  # hubot rundeck ad-hoc <name> <nodename>
  robot.respond /rundeck (?:ad[ -]?hoc) ([\w -_]+) ([\w-]+)/i, (msg) ->
    name = msg.match[1]
    params = { argString: "-nodename #{msg.match[2].trim().toLowerCase()}" }
    query = "?#{querystring.stringify(params)}"

    if robot.auth.hasRole(msg.envelope.user, rundeck.adminRole)
      rundeck.jobs().run name, query, (job, results) ->
        if job
          msg.send "Running job #{name}: #{results.result.executions[0].execution[0]['$'].href}"
        else
          msg.send "Could not execute Rundeck job \"#{name}\"."
    else
        msg.send "#{msg.envelope.user}: you do not have #{rundeck.adminRole} role."
