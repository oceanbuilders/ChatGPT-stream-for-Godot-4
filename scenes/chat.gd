extends Node2D

@export var api_key = "your-openai-apì-key"
# var max_tokens = 1024
@export var temperature = 0.5
@export var model = "gpt-3.5-turbo"
@export var stream : bool = true

# The HTTPSSE client doesn't support paralallel requests, so we need to keep
# track of when it is busy.
signal stream_busy(is_busy:bool)

var stream_reply_buffer: String
var stream_reply_final: String
var stream_used_status_ai_message = false
var stream_ongoing = false

var message_ai = preload("res://scenes/chat_message_ai.tscn")
var message_user = preload("res://scenes/chat_message_user.tscn")

enum types {AI,USER,SYSTEM,GODOT,STATUS}

var message_queue = []
var currently_processing = false # This indicates that a message is being processed
# These two variables are to keep the whole chat conversation locally
# and pass it to the LLM in future completion requests
var chat = []
var chat_message : String

var system_message : Dictionary

const VOICE_AI_SYSTEMS = {
	0 : "No AI speech",
	1 : "OS TTS",
	2 : "ElevenLabs",
}

var voice_ai_system : String = "OS TTS"
# This will hold the list of voice names for the current voice system
# which is OS TTS by default
var voices_list : Array = DisplayServer.tts_get_voices_for_language("en")
var OS_TTS_voices_list : Array
var eleven_labs_voice_names : Array
var eleven_labs_voice_names_to_voice_id: Dictionary

@export var word_by_word_delay : float = 0.1 # in seconds

# To chatGPT we do not pass the whole history,
# we control the context window with this variable (number of messages)
@export var chatgpt_history_length : int = 10

signal message_processed(message)
@onready var conversation_container = $ChatWindow/ConversationContainer
@onready var conversation = $ChatWindow/ConversationContainer/Conversation
@onready var voice_ai_system_selector = $ChatWindow/VoiceAISystemSelector
@onready var voice_selector = $ChatWindow/VoiceSelector

func _ready():
	message_processed.connect(_on_message_processed)
	# If no voices are fetched from the OS we can't offer OS TTS and we select
	# "No AI speech" by default
	if voices_list.size() == 0:
		voice_ai_system_selector.set_item_disabled(VOICE_AI_SYSTEMS.keys()[1],true)
		voice_ai_system_selector.select(VOICE_AI_SYSTEMS.keys()[0])
		voice_ai_system = VOICE_AI_SYSTEMS[0]
	else:
		if OS.get_name() == "Windows":
			for voice in voices_list:
				var parts = voice.split("\\")
				var voice_name = parts[-1] # Get the last part of the split string
				OS_TTS_voices_list.append(voice_name)
		else:
			OS_TTS_voices_list = voices_list
			
		for voice in OS_TTS_voices_list:
			voice_selector.add_item(voice)
	
	# This triggers a request to fetch the list of voices, it will be received
	# with a signal
	$ElevenLabsTTS.get_voices_list()
	
	# If stream == true we need to use server-side events, with the HTTPSSEClient add-on
	if stream:
		# $HTTPSSEClient.connected.connect(_on_connected)
		$HTTPSSEClient.new_sse_event.connect(_on_new_sse_event)
	
	# Prepare the system message
	system_message = {"role":"system", "content": "You are a helpful virtual assistant."}
	
	_insert_welcome_messages()

	
func _on_new_sse_event(partial_reply: Array, ai_status_message: ChatMessageAI):
	# print("partial_reply is: ", partial_reply)
	for string in partial_reply:
		
		if string == "[DONE]":
			$HTTPSSEClient.close_connection()
			# Whatever is reamining in the buffer, if any, must be sent to the 
			# RichTextLabel and voice ai service
			stream_ongoing = false
			
			if stream_reply_buffer.length() > 0:
				stream_reply_final += stream_reply_buffer
				_inject_message_from_stream(ai_status_message, stream_reply_buffer) 
				# We reset the buffer
				stream_reply_buffer = ""
				
			# We append the whole message to our internal chat
			chat.append({"role": "assistant", "content":stream_reply_final})
			# We reset the reply, ready for the next stream
			stream_reply_final = ""
			stream_used_status_ai_message = false
			
		elif string == "[EMPTY DELTA]":
			pass
		elif string == "[ERROR]":
			$HTTPSSEClient.close_connection()
			stream_ongoing = false
			# Whatever is reamining in the buffer, if any, must be sent to the 
			# RichTextLabel and voice ai service
			if stream_reply_buffer.length() > 0:
				stream_reply_final += stream_reply_buffer
				_inject_message_from_stream(ai_status_message, stream_reply_buffer) 
				# We reset the buffer and the reply
				stream_reply_buffer = ""
			stream_reply_final = ""
			stream_used_status_ai_message = false
		else:
			# We process the partial reply
			stream_reply_buffer += string
			# print("Current buffer: ", stream_reply_buffer)

			var paragraphs = stream_reply_buffer.split("\n\n")
			if paragraphs.size() > 1:
				var paragraph = paragraphs[0]
				stream_reply_final += paragraph
				_inject_message_from_stream(ai_status_message, paragraph) 
				# Remove the first paragraph
				paragraphs.remove_at(0)
				# Join the remaining paragraphs back together with "\n"
				stream_reply_buffer = "\n\n".join(paragraphs)
					
		# print("Final results after processing sentences:")
		# print("stream_reply_final=",stream_reply_final)
		# print("stream_reply_buffer=",stream_reply_buffer)

func _inject_message_from_stream(ai_status_message, text):
	if stream_used_status_ai_message:
		var ai_message = message_ai.instantiate()
		_insert_message(ai_message, text, types.AI)
	else:
		ai_status_message.bbcode_enabled = false
		_insert_message(ai_status_message, text, types.AI)
		stream_used_status_ai_message = true

func _call_gpt(prompt: String, ai_status_message: RichTextLabel) -> void:

	var messages = [system_message] # We create an array with the system message
	var last_N_messages = chat.slice(-chatgpt_history_length, chat.size(), 1) # Take the last N messages of the chat history
	messages.append_array(last_N_messages) # Append those N messages to the array
	# The reason why we treat the current prompt separately is that sometimes the prompt sent to
	# ChatGPT is different from the message shown to the user (which is what we store locally)
	var new_message = {"role": "user", "content": prompt} 
	messages.append(new_message) # we append now the prompt too.
	
	var host = "https://api.openai.com"
	var path = "/v1/chat/completions"
	var url = host+path

	var headers = [
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key
	]

	var body = JSON.stringify({
			"model": model,
			"messages": messages, # Send the array to chatGPT
			"temperature": temperature,
			"stream": stream,
	})
	
	print("Body of the message sent to ChatGPT: ", body)
	
	if stream:
		$HTTPSSEClient.connect_to_host(host, path, headers, body, ai_status_message, 443)
		stream_busy.emit(true)
		stream_ongoing = true
	else:
		var http_request = HTTPRequest.new()
		add_child(http_request)
		http_request.request_completed.connect(_on_call_gpt_completed.bind(http_request,ai_status_message))
		
		var error = http_request.request(url, headers, HTTPClient.METHOD_POST, body)
		
		if error != OK:
			push_error("Something Went Wrong!")


# This function is the callback of the signal that the HTTPRequest object fires
# THIS FUNCTION IS ONLY USED WHEN stream == false
func _on_call_gpt_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, emitter: HTTPRequest, message_ai)-> void:

	var ai_reply = message_ai
	ai_reply.bbcode_enabled = false
	var json = JSON.new()
	if response_code == 200:
		json.parse(body.get_string_from_utf8())
		var response = json.get_data()
		var clean_response = response.choices[0].message["content"]
		_insert_message(ai_reply, clean_response, types.AI)
		
	else:
		var text = "Sorry, there has been an error while processing the request, please try again."
		_insert_message(ai_reply, text, types.STATUS)
		printerr("Error code in response: ", response_code)
	# This is to remove the HTTPRquest node from the scene tree. Godot doesn't do this automatically.
	emitter.queue_free()

func _on_user_prompt_to_chat(text) -> void:
	var user_message = message_user.instantiate()
	var ai_message = message_ai.instantiate()
	_insert_message(user_message,text,types.USER)
	
	_call_gpt(text, ai_message)
	
	await get_tree().create_timer(0.5).timeout
	text = "[wave]Thinking...[wave]"
	ai_message.bbcode_enabled = true
	_insert_message(ai_message, text, types.STATUS)


func _insert_welcome_messages() -> void:
	await get_tree().create_timer(0.5).timeout
	var ai_message = message_ai.instantiate()
	var text = "[wave]Thinking...[wave]"
	ai_message.bbcode_enabled = true
	_insert_message(ai_message, text, types.STATUS)
	await get_tree().create_timer(1).timeout
	
	# await get_tree().process_frame
	text="[wave amp=20.0 freq=5.0]Hello there![/wave]"
	_insert_message(ai_message,text,types.GODOT)
	await get_tree().create_timer(1).timeout
	var ai_message2 = message_ai.instantiate()
	ai_message2.bbcode_enabled = false
	text = "This is ChatGPT. How can I help you today?"
	_insert_message(ai_message2,text,types.GODOT)


func strip_bbcode(source:String) -> String:
	var regex = RegEx.new()
	regex.compile("\\[.+?\\]")
	return regex.sub(source, "", true)
	

func _on_voice_ai_system_selector_item_selected(index: int) -> void:
	voice_ai_system = VOICE_AI_SYSTEMS[index]
	voice_selector.clear()
	voices_list = []
	if voice_ai_system == "OS TTS":
		voices_list = DisplayServer.tts_get_voices_for_language("en")
		for voice in OS_TTS_voices_list:
			voice_selector.add_item(voice)
	if voice_ai_system == "ElevenLabs":
		voices_list = eleven_labs_voice_names
		for voice in eleven_labs_voice_names:
			voice_selector.add_item(voice)
		print("voices_list: ", voices_list)

func _on_voice_selector_item_selected(index: int) -> void:
	if voice_ai_system == "ElevenLabs":
		$ElevenLabsTTS.set_voice_id(eleven_labs_voice_names_to_voice_id[eleven_labs_voice_names_to_voice_id.keys()[index]])


func _on_eleven_labs_tts_eleven_labs_voices_fetched(names, name_to_voice_id) -> void:
	if names.size() == 0:
		voice_ai_system_selector.set_item_disabled(VOICE_AI_SYSTEMS.keys()[2],true)
	eleven_labs_voice_names = names
	eleven_labs_voice_names_to_voice_id = name_to_voice_id



#######
## CHAT QUEUE SYSTEM
#######

func _insert_message(message: RichTextLabel, text: String, type: types ) -> void:
	# First we save the message to our local chat array
	if type != types.STATUS:
		# For storing in our internal chat array and for using voice_ai, we want to make sure there
		# is no BBCode on the text string
		var clean_text = strip_bbcode(text)
		if type == types.AI or type == types.GODOT:
			chat.append({"role": "assistant", "content":clean_text})
			if voice_ai_system == "OS TTS":
				DisplayServer.tts_speak(clean_text, voices_list[voice_selector.get_selected_id()])
			elif voice_ai_system == "ElevenLabs":
				$ElevenLabsTTS.call_ElevenLabs(clean_text)
			else: # this would mean "
				pass
		if type == types.USER:
			chat.append({"role": "user", "content":clean_text})
	print("Messages STORED LOCALLY: ",chat)
	# We inject the text into the interface message
	message.text = text
	# The message is added to the queue
	message_queue.append(message)
	# If the item added is the only one in the queue, start processing
	if message_queue.size() == 1:
		dequeue_and_process()


func dequeue_and_process():
	if message_queue.size() > 0 and currently_processing == false:
		var message = message_queue.pop_front()
		process_message(message)

func process_message(message):
	# First we extract the text from the RichTextLabel object
	var text = message.text
	currently_processing = true
	# We clear the message
	message.clear()
	
	# Checks if this is the last message of the stream
	if stream == true and stream_ongoing == false and message_queue.size() == 0:
		stream_busy.emit(false)
	
	# We only need to add a child for those messages we are not reusing
	# for example for those messages that replace "thinking..." we reause the child
	if not message.is_inside_tree():
		conversation.add_child(message)
	
	if not message.bbcode_enabled:
		# Split the text into words
		var words = text.split(" ")
		# Add words one by one with delay
		for index in words.size():
			message.add_text(words[index] + " ")  # Append the word plus a space
			await get_tree().create_timer(word_by_word_delay).timeout # Wait for 0.1 seconds
			if index == words.size() - 1:
				currently_processing = false
				emit_signal("message_processed", message)
	else:
		#if bbccode is enabled, to simplify things for now (bbc tags complicate things), we just inject the whole text at once
		message.append_text(text)
		currently_processing = false
		emit_signal("message_processed", message)

	
func _on_message_processed(message): # This is a custom signal method
	# Process the next item in the queue if any
	dequeue_and_process()

#######
## END OF chat queue system
#######
