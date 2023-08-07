extends Button

signal to_chat(text: String)
@onready var user_prompt = get_node("/root/chat/ChatWindow/UserPrompt")

func _ready() -> void:
	pressed.connect(_on_send_message_pressed)
	
	
func _on_send_message_pressed() -> void:
	if user_prompt.text != "":
		to_chat.emit(user_prompt.text)
		user_prompt.text = ""
		print("prompt text = ",user_prompt.text)
