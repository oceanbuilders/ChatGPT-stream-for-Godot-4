extends Button

signal to_chat(text: String)
@onready var user_prompt = get_node("/root/chat/ChatWindow/UserPrompt")
@onready var chat = get_node("/root/chat")


func _ready() -> void:
	pressed.connect(_on_send_message_pressed)
	chat.stream_busy.connect(_on_stream_busy)
	
func _on_stream_busy(is_busy):
	if is_busy:
		disabled = true
	else:
		disabled = false
	
func _on_send_message_pressed() -> void:
	if user_prompt.text != "":
		to_chat.emit(user_prompt.text)
		user_prompt.text = ""
		print("prompt text = ",user_prompt.text)
