extends ScrollContainer

var max_scroll_length = 0

@onready var scroll_bar = self.get_v_scroll_bar()

func _ready():
	# auto scrolling
	scroll_bar.changed.connect(_handle_scroll_bar_changed)
	max_scroll_length = scroll_bar.max_value
	

func _handle_scroll_bar_changed():
	if max_scroll_length != scroll_bar.max_value:
		max_scroll_length = scroll_bar.max_value    
		scroll_vertical = max_scroll_length
