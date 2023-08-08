extends TextEdit

signal to_chat(text: String)

var sending_enabled = true

@onready var chat = get_node("/root/chat")

func _ready() -> void:
	chat.stream_busy.connect(_on_stream_busy)

func _on_stream_busy(is_busy):
	if is_busy:
		sending_enabled = false
	else:
		sending_enabled = true

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_ENTER:
			if event.shift_pressed:
				# Shift+Enter was pressed, insert a new line
				insert_text_at_caret("\n")
			else:
				if sending_enabled:
					# Enter was pressed without Shift, send the text and clear the TextEdit
					to_chat.emit(text)
					# This is necessary because sometimes when pressing ENTER to send the text
					# a new line is inserted after the field is cleared, this is becuase 
					# by default Godot uses ENTER to enter new lines in the field
					# so we add a little delay in clearing the text
					await get_tree().create_timer(0.2).timeout 
					text = ""
					print("prompt text = ",text)
