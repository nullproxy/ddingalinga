require 'ffi-rzmq'
require 'msgpack'
require 'deep_fetch'
require_relative 'payload'
require_relative 'logging'

# Component worker thread class.
#
# This class handles component requests.
#
class ComponentServer

    @@WORKER_ENDPOINT = "inproc://workers"

	# Constants for response meta frame
	@@EMPTY_META = 0x00
	@@SERVICE_CALL = 0x01
	@@FILES = 0x02
	@@TRANSACTIONS = 0x03
	@@DOWNLOAD = 0x04

    # Multipart request frames
    @@Frames = Struct.new(:action, :mappings, :stream)


	def initialize(context = nil, callback = nil, cli_args = nil)
		@context = context
		@callback = callback
		@cli_args = cli_args
        @@Frames.new('action','mappings','stream')
	end

    def set_context(context)
        @context = context
    end

    def set_callback(callback)
        @callback = callback
    end

    def set_args(cli_args)
        @cli_args = cli_args
    end
    
    def component_name
        return @cli_args[:name]
    end

    def component_version
        return @cli_args[:version]
    end

    def component_title
        return return "'#{component_name}' (#{component_version})"
    end

    def framework_version
        return @cli_args[:framework_version]
	end

    def get_vars()        
        return @cli_args[:var]
    end

	# Check if debug is enabled for current component.
	#
	# :rtype: bool
	def debug
        return @cli_args[:debug]
    end

    # Check if payloads should use compact names.
    #
    # :rtype: bool
    def compact_names
        return @cli_args[:compact_names]
    end

	# Create a payload for the error response.
	#
    # :params exc: The exception raised in user land callback.
    # :type exc: `Exception`
    # :params component: The component being used.
    # :type component: `Component`
	#
    # :returns: A result payload.
    # :rtype: `Payload`
	def create_error_payload(exc, component, payload=nil)
        raise NotImplementedError.new("You must implement create_error_payload.")
    end


	# Create a component instance for a payload.
	#
    # The type of component created depends on the payload type.
	#
    # :param payload: A payload.
    # :type payload: Payload.
	#
    # :raises: HTTPError
	#
    # :returns: A component instance for the type of payload.
    # :rtype: `Component`.
   	def create_component_instance(payload)
       raise NotImplementedError.new("You must implement create_component_instance.")
    end

	# Convert callback result to a command result payload.
	#
    # :params command_name: Name of command being executed.
    # :type command_name: str
    # :params component: The component being used.
    # :type component: `Component`
    #
    # :returns: A command result payload.
    # :rtype: `CommandResultPayload`
    def component_to_payload(command_name, component)
        raise NotImplementedError.new("You must implement component_to_payload.")
    end

	# Process a request payload.
	# 
    # :param payload: A command payload.
    # :type payload: `CommandPayload`
    # 
    # :returns: A Payload with the component response.    
	def process_payload(payload)
        if payload.get_path("command") == nil
            Loggging.log.debug "Payload missing command"
            return ErrorPayload.new.init("Internal communication failed")
        end

        command_name = payload.get_path("command","name")

        # Create a component instance using the command payload and
        # call user land callback to process it and get a response component.
        component = create_component_instance(payload)


        # Call callback
        begin
            component = @callback.call(component)
        rescue Exception => exc
            Loggging.log.error "Exception: #{exc}"
            payload = create_error_payload(exc,component,payload)
        ensure
            # TODO 2 arguments for middleware => payload = component_to_payload(payload, component)
            payload = component_to_payload(payload, component) 
        end

        # Convert callback result to a command payload
        Loggging.log.debug " process_payload replay: #{CommandResultPayload.new.init(command_name,payload)}"
        return CommandResultPayload.new.init(command_name,payload) # return hash
               
	end


    # Process error when uses zmq
    def error_check(rc)
        if ZMQ::Util.resultcode_ok?(rc)
            false
        else
            Loggging.log.error "Operation failed, errno [#{ZMQ::Util.errno}] description [#{ZMQ::Util.error_string}]"
            caller(1).each { |callstack| Loggging.log.error(callstack) }
            true
        end
    end

    # Start handling incoming component requests and responses.
    #
    # This method starts an infinite loop that polls socket for
    # incoming requests.
    def run
        Loggging.log.debug "worker = #{component_name()} , Thread = #{Thread.current}"

        # When compact mode is enabled use long payload field names
        commandPayload = CommandPayload.new        
        commandPayload.set_fieldmappings(compact_names)

        # Socket to talk to dispatcher
        receiver = @context.socket(ZMQ::REP)
        receiver.connect(@@WORKER_ENDPOINT)

        loop do
            Loggging.log.debug "waiting to receive messages....."

            # receive menssage from userland (Multipart request frames = [action, mappings, stream])
            messages = []
            receiver.recvmsgs(messages)

            # 'action'
            received_action = messages[0]
            Loggging.log.debug "Received request byte 'action': [#{received_action.copy_out_string}]"

            # 'mappings'
            received_mappings = messages[1]
            Loggging.log.debug "Received request byte 'mappings': [#{received_mappings.copy_out_string}]"

            # 'stream'
            received_stream = messages[2]
            Loggging.log.debug "Received request byte: [#{received_stream.copy_out_string}]"

            # unpack message recived
            commandPayload.set_payload(MessagePack.unpack(received_stream.copy_out_string))
            Loggging.log.debug "Received commandPayload: [#{commandPayload}]"

            # Process message reviced
            commandResultPayload = process_payload(commandPayload)
            Loggging.log.debug "Responser commandResultPayload: [#{commandResultPayload}]"

            # send type of response
            meta = ZMQ::Message.new
            meta.copy_in_bytes([get_response_meta(commandPayload)].pack('C*'),1)
            Loggging.log.debug "Responser meta: [#{meta}]"            
            receiver.sendmsg(meta,ZMQ::SNDMORE)

            # Send reply back to client
            crmsg = ZMQ::Message.new(commandResultPayload.to_msgpack)
            receiver.sendmsg(crmsg)
        end
    end
end