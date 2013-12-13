_ = require 'underscore'
assert = require 'assert'
{EventEmitter} = require 'events'

BackoffTimer = require './backofftimer'
NodeState = require 'node-state'
{NSQDConnection} = require './nsqdconnection'
RoundRobinList = require './roundrobinlist'
StateChangeLogger = require './logging'

# Maintains the RDY and in-flight counts for a nsqd connection. ConnectionRdy
# ensures that the RDY count will not exceed the max set for this connection.
# The max for the connection can be adjusted at any time.
#
# Usage:
#
# connRdy = ConnectionRdy conn
# connRdy.setConnectionRdyMax 10
#
# conn.on 'message', ->
#   # On a successful message, bump up the RDY count for this connection.
#   connRdy.raise 'bump'
# conn.on 'requeue', ->
#   # We're backing off when we encounter a requeue. Wait 5 seconds to try
#   # again.
#   connRdy.raise 'backoff'
#   setTimeout (-> connRdy.raise 'bump'), 5000
#
class ConnectionRdy extends EventEmitter
  # Events emitted by ConnectionRdy
  @READY: 'ready'

  constructor: (@conn) ->
    @maxConnRdy = 0
    @inFlight = 0
    @lastRdySent = 0
    @idleId = null
    @statemachine = new ConnectionRdyState @

    @conn.on NSQDConnection.MESSAGE, =>
      clearTimeout @idleId if @idleId?
      @idleId = null
      @inFlight += 1
    @conn.on NSQDConnection.FINISHED, =>
      @inFlight -= 1
    @conn.on NSQDConnection.REQUEUED, =>
      @inFlight -= 1
    @conn.on NSQDConnection.SUBSCRIBED, =>
      @start()

  name: ->
    "#{@conn.conn.localPort}"

  start: ->
    @statemachine.start()
    @emit ConnectionRdy.READY

  setConnectionRdyMax: (maxConnRdy) ->
    # The RDY count for this connection should not exceed the max RDY count
    # configured for this nsqd connection.
    @maxConnRdy = Math.min maxConnRdy, @conn.maxRdyCount
    @statemachine.raise 'adjustMax'

  bump: ->
    @statemachine.raise 'bump'

  backoff: ->
    @statemachine.raise 'backoff'

  # Fires a backoff event if this connection is idle for a given period of
  # time. This is useful when maxInFlight is less than the number of
  # connections.
  backoffOnIdle: (maxIdleTime) ->
    @idleId = setTimeout (=> @backoff()), maxIdleTime

  isStarved: ->
    assert @inFlight <= @maxConnRdy
    @inFlight == @maxConnRdy

  setRdy: (rdyCount) ->
    @log "RDY #{rdyCount}"
    @conn.setRdy rdyCount if 0 <= rdyCount <= @maxConnRdy
    @lastRdySent = rdyCount

  log: (message='') ->
    msg = "#{@statemachine.current_state_name} #{message}"
    StateChangeLogger.log 'ConnectionRdy', @name(), msg


class ConnectionRdyState extends NodeState

  constructor: (@connRdy) ->
    super
      autostart: false,
      initial_state: 'INIT'
      sync_goto: true

  log: (message='') ->
    @connRdy.log message

  states:
    INIT:
      # RDY is implicitly zero
      bump: ->
        @goto 'MAX' if @connRdy.maxConnRdy > 0
      backoff: -> # No-op
      adjustMax: -> # No-op

    BACKOFF:
      Enter: ->
        @connRdy.setRdy 0
      bump: ->
        @goto 'ONE' if @connRdy.maxConnRdy > 0
      backoff: -> # No-op
      adjustMax: -> # No-op

    ONE:
      Enter: ->
        @connRdy.setRdy 1
      bump: ->
        @goto 'MAX'
      backoff: ->
        @goto 'BACKOFF'
      adjustMax: -> # No-op

    MAX:
      Enter: ->
        @raise 'bump'
      bump: ->
        @connRdy.setRdy @connRdy.maxConnRdy
      backoff: ->
        @goto 'BACKOFF'
      adjustMax: ->
        @log "adjustMax RDY #{@connRdy.maxConnRdy}"
        @connRdy.setRdy @connRdy.maxConnRdy

  transitions:
    '*':
      '*': (data, callback) ->
        @log()
        callback data


# backoffTime = 90
# heartbeat = 30
#
# [topic, channel] = ['sample', 'default']
# [host1, port1] = ['127.0.0.1', '4150']
# c1 = new NSQDConnection host1, port1, topic, channel, backoffTime, heartbeat
#
# readerRdy = new ReaderRdy 1, 128
# readerRdy.addConnection c1
#
# message = (msg) ->
#   console.log "Callback [message]: #{msg.attempts}, #{msg.body.toString()}"
#   if msg.attempts >= 5
#     msg.finish()
#     return
#
#   if msg.body.toString() is 'requeue'
#     msg.requeue()
#   else
#     msg.finish()
#
# discard = (msg) ->
#   console.log "Giving up on this message: #{msg.id}"
#   msg.finish()
#
# c1.on NSQDConnection.MESSAGE, message
# c1.connect()

class ReaderRdy extends NodeState

  # This will:
  # 1. Manage the RDY account across connections for this reader
  # 2. Handle backoff on failures across connections

  constructor: (@maxInFlight, maxBackoffDuration) ->
    super
      autostart: true,
      initial_state: 'ZERO'
      sync_goto: true

    @backoffTimer = new BackoffTimer 0, maxBackoffDuration
    @backoffId = null
    @balanceId = null
    @connections = []
    @roundRobinConnections = new RoundRobinList []

  isStarved: ->
    return false if _.isEmpty @connections
    not _.isEmpty (c for c in @connections if c.isStarved())

  createConnectionRdy: (conn) ->
    new ConnectionRdy conn

  isLowRdy: ->
    @maxInFlight < @connections.length

  addConnection: (conn) ->
    connectionRdy = @createConnectionRdy conn

    conn.on NSQDConnection.CLOSED, =>
      @removeConnection conn

    conn.on NSQDConnection.FINISHED, =>
      @backoffTimer.success()

      # When we're not in a low RDY situation, restore the consumed RDY count
      # to the connection that finished the message. If we are in a low RDY
      # situation, rebalance so that other connections can get a crack at
      # processing messages.
      if not @isLowRdy()
        connectionRdy.bump()
      else
        @balance()

      @raise 'success'

    conn.on NSQDConnection.REQUEUE, =>
      # Since there isn't a guaranteed order for the REQUEUE and BACKOFF
      # events, handle the case when we handle BACKOFF and then REQUEUE.
      if @current_state_name isnt 'BACKOFF'
        connectionRdy.bump()

    conn.on NSQDConnection.BACKOFF, =>
      @raise 'backoff'

    connectionRdy.on ConnectionRdy.READY, =>
      @connections.push connectionRdy
      @roundRobinConnections.add connectionRdy

      @balance()
      if @current_state_name is 'ZERO'
        @goto 'MAX'
      else if @current_state_name in ['TRY_ONE', 'MAX']
        connectionRdy.bump()

  removeConnection: (conn) ->
    @connections.splice @connections.indexOf(conn), 1
    @roundRobinConnections.remove conn

    if @connections.length is 0
      @goto 'ZERO'

  bump: ->
    # RDY 1 to each connection to test the waters.
    for conn in @connections
      conn.bump()

  try: ->
    @connections[0].bump()

  backoff: ->
    @backoffTimer.failure()

    for conn in @connections
      conn.backoff()

    if @backoffId
      clearTimeout @backoffId

    onTimeout = =>
      @raise 'try'

    @backoffId = setTimeout onTimeout, @backoffTimer.getInterval() * 1000

  inFlight: ->
    (c.inFlight for c in @connections).reduce (acc, entry) -> acc + entry

  # Evenly or fairly distributes RDY count based on the maxInFlight across
  # all nsqd connections.
  balance: ->
    # In the perverse situation where there are more connections than max in
    # flight, we do the following:
    #
    # There is a sliding window where each of the connections gets a RDY count
    # of 1. When the connection has processed it's single message, then the RDY
    # count is distributed to the next waiting connection. If the connection
    # does nothing with it's RDY count, then it should timeout and give it's
    # RDY count to another connection.

    max = if @current_state_name is 'TRY_ONE' then 1 else @maxInFlight
    perConnectionMax = Math.floor max / @connections.length

    # Low RDY and try conditions
    if perConnectionMax is 0
      # All connections have a max of 1 in low RDY situations.
      for c in @connections
        c.setConnectionRdyMax 1

      # Distribute available RDY count to the connections next in line.
      for c in @roundRobinConnections.next max - @inFlight()
        c.bump()
        c.backoffOnIdle 1000

      # Rebalance periodically. Needed when no messages are received.
      clearTimeout @balanceId if @balanceId
      @balanceId = setTimeout (=> @balance()), 1500

    else
      rdyRemainder = @maxInFlight % @connectionsLength
      for i in [0...@connections.length]
        connMax = perConnectionMax

        # Distribute the remainder RDY count evenly between the first
        # n connections.
        if rdyRemainder > 0
          connMax += 1
          rdyRemainder -= 1

        @connections[i].setConnectionRdyMax connMax

  log: (message='') ->
    msg = "#{@current_state_name} #{message}"
    StateChangeLogger.log 'ReaderRdy', null, msg

  # The following events results in transitions in the ReaderRdy state machine:
  # 1. Adding the first connection
  # 2. Remove the last connections
  # 3. Finish event from message handling
  # 4. Backoff event from message handling
  # 5. Backoff timeout
  states:
    ZERO:
      backoff: -> # No-op
      success: -> # No-op
      try: ->     # No-op

    TRY_ONE:
      Enter: ->
        @try()
      backoff: ->
        @goto 'BACKOFF'
      success: ->
        @goto 'MAX'
      try: -> # No-op

    MAX:
      Enter: ->
        @bump()
      backoff: ->
        @goto 'BACKOFF'
      success: -> # No-op
      try: -> # No-op

    BACKOFF:
      Enter: ->
        @backoff()
      backoff: ->
        @backoff()
      success: -> # No-op
      try: ->
        @goto 'TRY_ONE'

  transitions:
   '*':
      '*': (data, callback) ->
        @log()
        callback data


module.exports =
  ReaderRdy: ReaderRdy
  ConnectionRdy: ConnectionRdy