#     NoFlo - Flow-Based Programming for JavaScript
#     (c) 2013-2016 TheGrid (Rituwall Inc.)
#     (c) 2011-2012 Henri Bergius, Nemein
#     NoFlo may be freely distributed under the MIT license
#
# Baseclass for regular NoFlo components.
{EventEmitter} = require 'events'

ports = require './Ports'
IP = require './IP'

debug = require('debug') 'noflo:component'
debugBrackets = require('debug') 'noflo:component:brackets'
debugSend = require('debug') 'noflo:component:send'

class Component extends EventEmitter
  description: ''
  icon: null

  constructor: (options) ->
    options = {} unless options
    options.inPorts = {} unless options.inPorts
    if options.inPorts instanceof ports.InPorts
      @inPorts = options.inPorts
    else
      @inPorts = new ports.InPorts options.inPorts

    options.outPorts = {} unless options.outPorts
    if options.outPorts instanceof ports.OutPorts
      @outPorts = options.outPorts
    else
      @outPorts = new ports.OutPorts options.outPorts

    @icon = options.icon if options.icon
    @description = options.description if options.description

    @started = false
    @load = 0
    @ordered = options.ordered ? false
    @autoOrdering = options.autoOrdering ? null
    @outputQ = []
    @bracketContext = {}
    @activateOnInput = options.activateOnInput ? true
    @forwardBrackets = in: ['out', 'error']

    if 'forwardBrackets' of options
      @forwardBrackets = options.forwardBrackets

    if typeof options.process is 'function'
      @process options.process

  getDescription: -> @description

  isReady: -> true

  isSubgraph: -> false

  setIcon: (@icon) ->
    @emit 'icon', @icon
  getIcon: -> @icon

  error: (e, groups = [], errorPort = 'error', scope = null) =>
    if @outPorts[errorPort] and (@outPorts[errorPort].isAttached() or not @outPorts[errorPort].isRequired())
      @outPorts[errorPort].openBracket group, scope: scope for group in groups
      @outPorts[errorPort].data e, scope: scope
      @outPorts[errorPort].closeBracket group, scope: scope for group in groups
      # @outPorts[errorPort].disconnect()
      return
    throw e

  shutdown: ->
    return unless @started
    inPorts = @inPorts.ports or @inPorts
    inPort.clear() for inPort in inPorts
    @bracketContext = {}
    callback = =>
      @started = false
      @emit 'end'
    if @load > 0
      @on 'deactivate', =>
        callback() if @load is 0
    else
      callback()

  # The startup function performs initialization for the component.
  start: ->
    return if @started
    @started = true
    @emit 'start'
    @started

  isStarted: -> @started

  # Ensures braket forwarding map is correct for the existing ports
  prepareForwarding: ->
    for inPort, outPorts of @forwardBrackets
      unless inPort of @inPorts.ports
        delete @forwardBrackets[inPort]
        continue
      tmp = []
      for outPort in outPorts
        tmp.push outPort if outPort of @outPorts.ports
      if tmp.length is 0
        delete @forwardBrackets[inPort]
      else
        @forwardBrackets[inPort] = tmp

  isLegacy: ->
    # Process API
    return false if @handle
    # WirePattern
    return false if @_wpData
    # Legacy
    true

  # Sets process handler function
  process: (handle) ->
    unless typeof handle is 'function'
      throw new Error "Process handler must be a function"
    unless @inPorts
      throw new Error "Component ports must be defined before process function"
    @prepareForwarding()
    @handle = handle
    for name, port of @inPorts.ports
      do (name, port) =>
        port.name = name unless port.name
        port.on 'ip', (ip) =>
          @handleIP ip, port
    @

  isForwardingInport: (port) ->
    if typeof port is 'string'
      portName = port
    else
      portName = port.name
    if portName of @forwardBrackets
      return true
    false

  isForwardingOutport: (inport, outport) ->
    if typeof inport is 'string'
      inportName = inport
    else
      inportName = inport.name
    if typeof outport is 'string'
      outportName = outport
    else
      outportName = outport.name
    return false unless @forwardBrackets[inportName]
    return true if @forwardBrackets[inportName].indexOf(outportName) isnt -1
    false

  isOrdered: ->
    return true if @ordered
    return true if @autoOrdering
    false

  # The component has received an Information Packet. Call the processing function
  # so that firing pattern preconditions can be checked and component can do
  # processing as needed.
  handleIP: (ip, port) ->
    unless port.options.triggering
      # If port is non-triggering, we can skip the process function call
      return

    if ip.type is 'openBracket' and @autoOrdering is null and not @ordered
      # Switch component to ordered mode when receiving a stream unless
      # auto-ordering is disabled
      debug "#{@nodeId} port '#{port.name}' entered auto-ordering mode"
      @autoOrdering = true

    # Initialize the result object for situations where output needs
    # to be queued to be kept in order
    result = {}

    if @isForwardingInport port
      # For bracket-forwarding inports we need to initialize a bracket context
      # so that brackets can be sent as part of the output, and closed after.
      if ip.type is 'openBracket'
        # For forwarding ports openBrackets don't fire
        return

      if ip.type is 'closeBracket'
        # For forwarding ports closeBrackets don't fire
        # However, we need to handle several different scenarios:
        # A. There are closeBrackets in queue before current packet
        # B. There are closeBrackets in queue after current packet
        # C. We've queued the results from all in-flight processes and
        #    new closeBracket arrives
        buf = port.getBuffer ip.scope, ip.index
        dataPackets = buf.filter (ip) -> ip.type is 'data'
        if @outputQ.length >= @load and dataPackets.length is 0
          return unless buf[0] is ip
          # Remove from buffer
          port.get ip.scope, ip.index
          context = @getBracketContext(port.name, ip.scope, ip.index).pop()
          context.closeIp = ip
          debugBrackets "#{@nodeId} closeBracket-C from '#{context.source}' to #{context.ports}: '#{ip.data}'"
          result =
            __resolved: true
            __bracketClosingAfter: [context]
          @outputQ.push result
          do @processOutputQueue
        # Check if buffer contains data IPs. If it does, we want to allow
        # firing
        return unless dataPackets.length

    # Prepare the input/output pair
    context = new ProcessContext ip, @, port, result
    input = new ProcessInput @inPorts, context
    output = new ProcessOutput @outPorts, context
    try
      # Call the processing function
      @handle input, output, context
    catch e
      @deactivate context
      output.sendDone e

    return if context.activated
    if port.isAddressable()
      debug "#{@nodeId} packet on '#{port.name}[#{ip.index}]' didn't match preconditions: #{ip.type}"
      return
    debug "#{@nodeId} packet on '#{port.name}' didn't match preconditions: #{ip.type}"
    return

  getBracketContext: (port, scope, idx) ->
    portname = port
    if @inPorts[port].isAddressable()
      portname = "#{port}[#{idx}]"
    # Ensure we have a bracket context for the current scope
    @bracketContext[portname] = {} unless @bracketContext[portname]
    @bracketContext[portname][scope] = [] unless @bracketContext[portname][scope]
    return @bracketContext[portname][scope]

  addToResult: (result, port, ip, before = false) ->
    if port.indexOf('[') is -1
      # Regular port
      outport = port
    else
      [port, outport, idx] = port.match /(.*)\[([0-9+])\]/
    method = if before then 'unshift' else 'push'
    if @outPorts[outport].isAddressable()
      idx = if idx then parseInt(idx) else ip.index
      result[outport] = {} unless result[outport]
      result[outport][idx] = [] unless result[outport][idx]
      ip.index = idx
      result[outport][idx][method] ip
      return
    result[outport] = [] unless result[outport]
    result[outport][method] ip

  addBracketForwards: (result) ->
    if result.__bracketClosingBefore?.length
      for context in result.__bracketClosingBefore
        debugBrackets "#{@nodeId} closeBracket-A from '#{context.source}' to #{context.ports}: '#{context.closeIp.data}'"
        continue unless context.ports.length
        for port in context.ports
          ipClone = context.closeIp.clone()
          @addToResult result, port, ipClone, true

    if result.__bracketContext
      # First see if there are any brackets to forward. We need to reverse
      # the keys so that they get added in correct order
      Object.keys(result.__bracketContext).reverse().forEach (inport) =>
        context = result.__bracketContext[inport]
        return unless context.length
        for outport, ips of result
          continue if outport.indexOf('__') is 0
          if @outPorts[outport].isAddressable()
            for idx, idxIps of ips
              # Don't register indexes we're only sending brackets to
              datas = idxIps.filter (ip) -> ip.type is 'data'
              continue unless datas.length
              portIdentifier = "#{outport}[#{idx}]"
              unforwarded = context.filter (ctx) =>
                return false unless @isForwardingOutport inport, outport
                ctx.ports.indexOf(portIdentifier) is -1
              continue unless unforwarded.length
              unforwarded.reverse()
              for ctx in unforwarded
                ipClone = ctx.ip.clone()
                ipClone.index = parseInt idx
                idxIps.unshift ipClone
                debugBrackets "#{@nodeId} register from '#{inport}' to '#{portIdentifier}' < '#{ctx.ip.data}'"
                ctx.ports.push portIdentifier
            continue
          # Don't register ports we're only sending brackets to
          datas = ips.filter (ip) -> ip.type is 'data'
          continue unless datas.length
          unforwarded = context.filter (ctx) =>
            return false unless @isForwardingOutport inport, outport
            ctx.ports.indexOf(outport) is -1
          continue unless unforwarded.length
          unforwarded.reverse()
          for ctx in unforwarded
            ips.unshift ctx.ip.clone()
            debugBrackets "#{@nodeId} register from '#{inport}' to '#{outport}' < '#{ctx.ip.data}'"
            ctx.ports.push outport

    if result.__bracketClosingAfter?.length
      for context in result.__bracketClosingAfter
        debugBrackets "#{@nodeId} closeBracket-B from '#{context.source}' to #{context.ports}: '#{context.closeIp.data}'"
        continue unless context.ports.length
        for port in context.ports
          ipClone = context.closeIp.clone()
          @addToResult result, port, ipClone, false

    delete result.__bracketClosingBefore
    delete result.__bracketContext
    delete result.__bracketClosingAfter

  processOutputQueue: ->
    while @outputQ.length > 0
      result = @outputQ[0]
      break unless result.__resolved
      @addBracketForwards result
      for port, ips of result
        continue if port.indexOf('__') is 0
        if @outPorts.ports[port].isAddressable()
          for idx, idxIps of ips
            idx = parseInt idx
            continue unless @outPorts.ports[port].isAttached idx
            for ip in idxIps
              portIdentifier = "#{port}[#{ip.index}]"
              if ip.type is 'openBracket'
                debugSend "#{@nodeId} sending #{portIdentifier} < '#{ip.data}'"
              else if ip.type is 'closeBracket'
                debugSend "#{@nodeId} sending #{portIdentifier} > '#{ip.data}'"
              else
                debugSend "#{@nodeId} sending #{portIdentifier} DATA"
              @outPorts[port].sendIP ip
          continue
        continue unless @outPorts.ports[port].isAttached()
        for ip in ips
          portIdentifier = port
          if ip.type is 'openBracket'
            debugSend "#{@nodeId} sending #{portIdentifier} < '#{ip.data}'"
          else if ip.type is 'closeBracket'
            debugSend "#{@nodeId} sending #{portIdentifier} > '#{ip.data}'"
          else
            debugSend "#{@nodeId} sending #{portIdentifier} DATA"
          @outPorts[port].sendIP ip
      @outputQ.shift()

  activate: (context) ->
    return if context.activated # prevent double activation
    # Start if not started already
    do @start unless @started
    context.activated = true
    context.deactivated = false
    @load++
    @emit 'activate', @load
    if @ordered or @autoOrdering
      @outputQ.push context.result

  deactivate: (context) ->
    return if context.deactivated # prevent double deactivation
    context.deactivated = true
    context.activated = false
    if @ordered or @autoOrdering
      @processOutputQueue()
    @load--
    @emit 'deactivate', @load

exports.Component = Component

class ProcessContext
  constructor: (@ip, @nodeInstance, @port, @result) ->
    @scope = @ip.scope
    @activated = false
    @deactivated = false
  activate: ->
    # Push a new result value if previous has been sent already
    if @result.__resolved or @nodeInstance.outputQ.indexOf(@result) is -1
      @result = {}
    @nodeInstance.activate @
  deactivate: ->
    @result.__resolved = true unless @result.__resolved
    @nodeInstance.deactivate @

class ProcessInput
  constructor: (@ports, @context) ->
    @nodeInstance = @context.nodeInstance
    @ip = @context.ip
    @port = @context.port
    @result = @context.result
    @scope = @context.scope

  # When preconditions are met, set component state to `activated`
  activate: ->
    return if @context.activated
    if @nodeInstance.isOrdered()
      # We're handling packets in order. Set the result as non-resolved
      # so that it can be send when the order comes up
      @result.__resolved = false
    @nodeInstance.activate @context
    if @port.isAddressable()
      debug "#{@nodeInstance.nodeId} packet on '#{@port.name}[#{@ip.index}]' caused activation #{@nodeInstance.load}: #{@ip.type}"
    else
      debug "#{@nodeInstance.nodeId} packet on '#{@port.name}' caused activation #{@nodeInstance.load}: #{@ip.type}"

  # ## Connection listing
  # This allows components to check which input ports are attached. This is
  # useful mainly for addressable ports
  attached: (args...) ->
    args = ['in'] unless args.length
    res = []
    for port in args
      res.push @ports[port].listAttached()
    return res.pop() if args.length is 1
    res

  # ## Input preconditions
  # When the processing function is called, it can check if input buffers
  # contain the packets needed for the process to fire.
  # This precondition handling is done via the `has` and `hasStream` methods.

  # Returns true if a port (or ports joined by logical AND) has a new IP
  # Passing a validation callback as a last argument allows more selective
  # checking of packets.
  has: (args...) ->
    args = ['in'] unless args.length
    if typeof args[args.length - 1] is 'function'
      validate = args.pop()
    else
      validate = -> true
    for port in args
      if Array.isArray port
        unless @ports[port[0]].isAddressable()
          throw new Error "Non-addressable ports, access must be with string #{port[0]}"
        return false unless @ports[port[0]].has @scope, port[1], validate
        continue
      if @ports[port].isAddressable()
        throw new Error "For addressable ports, access must be with array [#{port}, idx]"
      return false unless @ports[port].has @scope, validate
    return true

  # Returns true if the ports contain data packets
  hasData: (args...) ->
    args = ['in'] unless args.length
    args.push (ip) -> ip.type is 'data'
    return @has.apply @, args

  # Returns true if a port has a complete stream in its input buffer.
  hasStream: (args...) ->
    args = ['in'] unless args.length
    for port in args
      portBrackets = []
      hasData = false
      validate = (ip) ->
        if ip.type is 'openBracket'
          portBrackets.push ip.data
          return false
        if ip.type is 'data'
          # Data IP on its own is a valid stream
          return true unless portBrackets.length
          # Otherwise we need to check for complete stream
          hasData = true
          return false
        if ip.type is 'closeBracket'
          portBrackets.pop()
          return false if portBrackets.length
          return false unless hasData
          return true
      return false unless @has port, validate
    true

  # ## Input processing
  #
  # Once preconditions have been met, the processing function can read from
  # the input buffers. Reading packets sets the component as "activated".
  #
  # Fetches IP object(s) for port(s)
  get: (args...) ->
    @activate()
    args = ['in'] unless args.length
    res = []
    for port in args
      if Array.isArray port
        [portname, idx] = port
        unless @ports[portname].isAddressable()
          throw new Error 'Non-addressable ports, access must be with string portname'
      else
        portname = port
        if @ports[portname].isAddressable()
          throw new Error 'For addressable ports, access must be with array [portname, idx]'
      if @nodeInstance.isForwardingInport portname
        ip = @__getForForwarding portname, idx
        res.push ip
        continue
      ip = @ports[portname].get @scope, idx
      res.push ip

    if args.length is 1 then res[0] else res

  __getForForwarding: (port, idx) ->
    prefix = []
    dataIp = null
    # Read IPs until we hit data
    loop
      # Read next packet
      ip = @ports[port].get @scope, idx
      # Stop at the end of the buffer
      break unless ip
      if ip.type is 'data'
        # Hit the data IP, stop here
        dataIp = ip
        break
      # Keep track of bracket closings and openings before
      prefix.push ip

    # Forwarding brackets that came before data packet need to manipulate context
    # and be added to result so they can be forwarded correctly to ports that
    # need them
    for ip in prefix
      if ip.type is 'closeBracket'
        # Bracket closings before data should remove bracket context
        @result.__bracketClosingBefore = [] unless @result.__bracketClosingBefore
        context = @nodeInstance.getBracketContext(port, @scope, idx).pop()
        context.closeIp = ip
        @result.__bracketClosingBefore.push context
        continue
      if ip.type is 'openBracket'
        # Bracket openings need to go to bracket context
        @nodeInstance.getBracketContext(port, @scope, idx).push
          ip: ip
          ports: []
          source: port
        continue

    # Add current bracket context to the result so that when we send
    # to ports we can also add the surrounding brackets
    @result.__bracketContext = {} unless @result.__bracketContext
    @result.__bracketContext[port] = @nodeInstance.getBracketContext(port, @scope, idx).slice 0
    # Bracket closings that were in buffer after the data packet need to
    # be added to result for done() to read them from
    return dataIp

  # Fetches `data` property of IP object(s) for given port(s)
  getData: (args...) ->
    args = ['in'] unless args.length

    datas = []
    for port in args
      packet = @get port
      unless packet?
        # we add the null packet to the array so when getting
        # multiple ports, if one is null we still return it
        # so the indexes are correct.
        datas.push packet
        continue

      until packet.type is 'data'
        packet = @get port
        break unless packet

      packet = packet?.data ? undefined
      datas.push packet

    return datas.pop() if args.length is 1
    datas

  # Fetches a complete data stream from the buffer.
  getStream: (args...) ->
    args = ['in'] unless args.length
    datas = []
    for port in args
      portBrackets = []
      portPackets = []
      hasData = false
      ip = @get port
      datas.push undefined unless ip
      while ip
        if ip.type is 'openBracket'
          unless portBrackets.length
            # First openBracket in stream, drop previous
            portPackets = []
            hasData = false
          portBrackets.push ip.data
          portPackets.push ip
        if ip.type is 'data'
          portPackets.push ip
          hasData = true
          # Unbracketed data packet is a valid stream
          break unless portBrackets.length
        if ip.type is 'closeBracket'
          portPackets.push ip
          portBrackets.pop()
          if hasData and not portBrackets.length
            # Last close bracket finishes stream if there was data inside
            break
        ip = @get port
      datas.push portPackets

    return datas.pop() if args.length is 1
    datas

class ProcessOutput
  constructor: (@ports, @context) ->
    @nodeInstance = @context.nodeInstance
    @ip = @context.ip
    @result = @context.result
    @scope = @context.scope

  # Checks if a value is an Error
  isError: (err) ->
    err instanceof Error or
    Array.isArray(err) and err.length > 0 and err[0] instanceof Error

  # Sends an error object
  error: (err) ->
    multiple = Array.isArray err
    err = [err] unless multiple
    if 'error' of @ports and
    (@ports.error.isAttached() or not @ports.error.isRequired())
      @sendIP 'error', new IP 'openBracket' if multiple
      @sendIP 'error', e for e in err
      @sendIP 'error', new IP 'closeBracket' if multiple
    else
      throw e for e in err

  # Sends a single IP object to a port
  sendIP: (port, packet) ->
    unless IP.isIP packet
      ip = new IP 'data', packet
    else
      ip = packet
    ip.scope = @scope if @scope isnt null and ip.scope is null

    if @nodeInstance.outPorts[port].isAddressable() and ip.index is null
      throw new Error 'Sending packets to addressable ports requires specifying index'

    if @nodeInstance.isOrdered()
      @nodeInstance.addToResult @result, port, ip
      return
    @nodeInstance.outPorts[port].sendIP ip

  # Sends packets for each port as a key in the map
  # or sends Error or a list of Errors if passed such
  send: (outputMap) ->
    return @error outputMap if @isError outputMap

    componentPorts = []
    mapIsInPorts = false
    for port in Object.keys @ports.ports
      componentPorts.push port if port isnt 'error' and port isnt 'ports' and port isnt '_callbacks'
      if not mapIsInPorts and outputMap? and typeof outputMap is 'object' and Object.keys(outputMap).indexOf(port) isnt -1
        mapIsInPorts = true

    if componentPorts.length is 1 and not mapIsInPorts
      @sendIP componentPorts[0], outputMap
      return

    if componentPorts.length > 1 and not mapIsInPorts
      throw new Error 'Port must be specified for sending output'

    for port, packet of outputMap
      @sendIP port, packet

  # Sends the argument via `send()` and marks activation as `done()`
  sendDone: (outputMap) ->
    @send outputMap
    @done()

  # Makes a map-style component pass a result value to `out`
  # keeping all IP metadata received from `in`,
  # or modifying it if `options` is provided
  pass: (data, options = {}) ->
    unless 'out' of @ports
      throw new Error 'output.pass() requires port "out" to be present'
    for key, val of options
      @ip[key] = val
    @ip.data = data
    @sendIP 'out', @ip
    @done()

  # Finishes process activation gracefully
  done: (error) ->
    @result.__resolved = true
    @nodeInstance.activate @context
    @error error if error

    isLast = =>
      # We only care about real output sets with processing data
      resultsOnly = @nodeInstance.outputQ.filter (q) ->
        return true unless q.__resolved
        if Object.keys(q).length is 2 and q.__bracketClosingAfter
          return false
        true
      pos = resultsOnly.indexOf @result
      len = resultsOnly.length
      load = @nodeInstance.load
      return true if pos is len - 1
      return true if pos is -1 and load is len + 1
      return true if len <= 1 and load is 1
      false
    if @nodeInstance.isOrdered() and isLast()
      # We're doing bracket forwarding. See if there are
      # dangling closeBrackets in buffer since we're the
      # last running process function.
      for port, contexts of @nodeInstance.bracketContext
        continue unless contexts[@scope]
        nodeContext = contexts[@scope]
        continue unless nodeContext.length
        context = nodeContext[nodeContext.length - 1]
        buf = @nodeInstance.inPorts[context.source].getBuffer context.ip.scope, context.ip.index
        loop
          break unless buf.length
          break unless buf[0].type is 'closeBracket'
          ip = @nodeInstance.inPorts[context.source].get context.ip.scope, context.ip.index
          ctx = nodeContext.pop()
          ctx.closeIp = ip
          @result.__bracketClosingAfter = [] unless @result.__bracketClosingAfter
          @result.__bracketClosingAfter.push ctx

    debug "#{@nodeInstance.nodeId} finished processing #{@nodeInstance.load}"

    if @nodeInstance.isOrdered()
      @result.__resolved = true
      @nodeInstance.processOutputQueue()
    @nodeInstance.deactivate @context
