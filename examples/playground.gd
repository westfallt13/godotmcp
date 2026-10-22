extends Node2D
var presses := 0
var steps := 0

func _ready() -> void:
	print("Hermes playground ready")
	queue_redraw()

func _process(delta: float) -> void:
	steps += 1
	if Input.is_action_pressed("ui_right"):
		$Player.position.x += 180.0 * delta
	if Input.is_action_pressed("ui_left"):
		$Player.position.x -= 180.0 * delta
	$Status.text = "Hermes MCP playground\nArrow keys move the square. Space/Enter increments the counter.\nPresses: %d" % presses

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		presses += 1
		print("Playground presses: ", presses)

func _draw() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color("142235"))
	draw_line(Vector2(40, 400), Vector2(920, 400), Color("426079"), 3.0)

func add_numbers(a: int, b: int) -> int:
	return a + b
