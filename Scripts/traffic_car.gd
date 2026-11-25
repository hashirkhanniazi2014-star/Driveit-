class_name TrafficCar
extends Node2D
## Oncoming traffic. The sprite is turned 180° so it faces the player.
## Taxis (the yellow hatchback) blink the front lamp on the side they will move
## toward, then change lane. Every car has headlight beams that point at the player.
## Scene needed: TrafficCar (this script) with ONE child, a Sprite2D named Body.
## The blinker lamps and the beams are all created here in code.

enum State { DRIVING, SIGNALING, CHANGING, DONE }

const LANES: Array[float] = [120.0, 240.0, 360.0, 480.0, 600.0]

const BLINK_HALF_PERIOD := 0.25   # real seconds on / off
const SIGNAL_TIME := 1.0          # warning before the car moves
const CHANGE_TIME := 0.7          # how long the move takes
const TAXI_CHANGE_CHANCE := 0.9   # taxis almost always change lane
const TAXI_AGAIN_CHANCE := 0.4    # chance of swerving a second time
const REF_CLOSING := 550.0        # closing speed the times above are tuned for

# Amber blinker lamps (hidden until the car signals). Their soft glow texture is
# generated in code (see _get_glow), so no glow.png file is needed.
const BLINK_COLOR := Color(1.0, 0.6, 0.1)
const BLINK_ENERGY := 2.0
const BLINK_SCALE := 0.6

# Headlight beams: a PointLight2D with the cone texture, pointing DOWN at the player.
const CONE: Texture2D = preload("res://Assets/light_cone.png")
const BEAM_COLOR := Color(1.0, 0.95, 0.8)
const BEAM_ENERGY := 0.9
const BEAM_SCALE := 0.7           # 1.0 = full 512 px beam
const TWIN_BEAMS := true          # false = one beam per car (cheaper)

# half = hitbox half-size, lamp = front lamp offset from centre (car faces DOWN),
# spd = own speed range (px/s), added to the player's speed
const TYPES := [
	{tex = preload("res://Assets/car_traffic_0.png"), half = Vector2(30, 56), lamp = Vector2(16, 47), spd = Vector2(90, 140)},
	{tex = preload("res://Assets/car_traffic_1.png"), half = Vector2(30, 56), lamp = Vector2(16, 47), spd = Vector2(90, 140), taxi = true},
	{tex = preload("res://Assets/car_traffic_2.png"), half = Vector2(30, 56), lamp = Vector2(17, 47), spd = Vector2(80, 120)},
	{tex = preload("res://Assets/car_traffic_3.png"), half = Vector2(30, 56), lamp = Vector2(16, 47), spd = Vector2(90, 140)},
	{tex = preload("res://Assets/car_traffic_4.png"), half = Vector2(30, 56), lamp = Vector2(16, 47), spd = Vector2(90, 140)},
	{tex = preload("res://Assets/car_traffic_5.png"), half = Vector2(30, 56), lamp = Vector2(16, 46), spd = Vector2(110, 160)},
	{tex = preload("res://Assets/truck_pickup.png"), half = Vector2(32, 66), lamp = Vector2(18, 56), spd = Vector2(80, 110)},
	{tex = preload("res://Assets/truck_box_small.png"), half = Vector2(34, 84), lamp = Vector2(17, 80), spd = Vector2(70, 100)},
	{tex = preload("res://Assets/truck_box_big.png"), half = Vector2(38, 110), lamp = Vector2(19, 105), spd = Vector2(55, 80)},
	{tex = preload("res://Assets/truck_semi.png"), half = Vector2(42, 170), lamp = Vector2(23, 161), spd = Vector2(45, 65)},
]

var own_speed := 100.0
var half_size := Vector2(30, 56)
var lane := 2
var target_lane := 2
var player_speed := 450.0     # main.gd updates this every frame

var state := State.DRIVING
var will_change := false
var trigger_y := 0.0          # starts signalling once the car reaches this y
var timer := 0.0
var blink_clock := 0.0
var dir := 0
var from_x := 0.0
var change_t := 0.0

var blink_left: PointLight2D  # created in setup()
var blink_right: PointLight2D

@onready var body: Sprite2D = $Body


func setup(type_index: int, lane_index: int) -> void:
	var t: Dictionary = TYPES[type_index]
	body.texture = t.tex
	body.rotation = PI                          # face the player
	half_size = t.half
	blink_left = _make_blinker(Vector2(-t.lamp.x, t.lamp.y))
	blink_right = _make_blinker(Vector2(t.lamp.x, t.lamp.y))
	_make_beams(t.lamp)
	own_speed = randf_range(t.spd.x, t.spd.y)
	lane = lane_index
	target_lane = lane_index
	position.x = LANES[lane]
	will_change = bool(t.get("taxi", false)) and randf() < TAXI_CHANGE_CHANCE
	trigger_y = randf_range(-40.0, 120.0)
	_lamps_off()


static var _glow: GradientTexture2D     # built once, shared by every car


static func _get_glow() -> GradientTexture2D:
	if _glow == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.35, 0.7, 1.0])
		g.colors = PackedColorArray([
			Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.39), Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.0)])
		_glow = GradientTexture2D.new()
		_glow.gradient = g
		_glow.fill = GradientTexture2D.FILL_RADIAL
		_glow.fill_from = Vector2(0.5, 0.5)
		_glow.fill_to = Vector2(1.0, 0.5)
		_glow.width = 128
		_glow.height = 128
	return _glow


func _make_blinker(pos: Vector2) -> PointLight2D:
	var lamp := PointLight2D.new()
	lamp.texture = _get_glow()
	lamp.texture_scale = BLINK_SCALE
	lamp.color = BLINK_COLOR
	lamp.energy = BLINK_ENERGY
	lamp.position = pos
	lamp.visible = false
	add_child(lamp)
	return lamp


func _make_beams(lamp: Vector2) -> void:
	var sides: Array = [-1.0, 1.0] if TWIN_BEAMS else [0.0]
	var half_len := CONE.get_height() * BEAM_SCALE * 0.5
	for side: float in sides:
		# The pivot sits on the lamp and is turned 180° so the beam points down.
		var pivot := Node2D.new()
		pivot.position = Vector2(side * lamp.x, lamp.y)
		pivot.rotation = PI
		add_child(pivot)

		# The cone's narrow tip is the bottom-centre of the image. Moving the light
		# up by half its length puts that tip exactly on the pivot (the lamp), and
		# the wide end then spreads out in front of the car.
		var beam := PointLight2D.new()
		beam.texture = CONE
		beam.texture_scale = BEAM_SCALE
		beam.color = BEAM_COLOR
		beam.energy = BEAM_ENERGY
		beam.position = Vector2(0.0, -half_len)
		pivot.add_child(beam)


func _process(delta: float) -> void:
	# The faster we close in, the faster the sequence plays, so you always see it.
	var pace := maxf((player_speed + own_speed) / REF_CLOSING, 1.0)
	var dt := delta * pace

	match state:
		State.DRIVING:
			if will_change and position.y >= trigger_y:
				_try_signal()
		State.SIGNALING:
			_blink(delta)                       # blinking stays in real time
			timer -= dt
			if timer <= 0.0:
				_start_change()
		State.CHANGING:
			_blink(delta)
			change_t = minf(change_t + dt / CHANGE_TIME, 1.0)
			position.x = lerpf(from_x, LANES[target_lane], smoothstep(0.0, 1.0, change_t))
			rotation = -dir * 0.12 * sin(PI * change_t)   # nose turns into the move
			if change_t >= 1.0:
				lane = target_lane
				rotation = 0.0
				_lamps_off()
				if randf() < TAXI_AGAIN_CHANCE:      # unpredictable: swerve again later
					state = State.DRIVING
					will_change = true
					trigger_y = position.y + randf_range(150.0, 300.0)
				else:
					state = State.DONE


func _try_signal() -> void:
	var options: Array[int] = []
	if lane > 0 and _lane_is_free(lane - 1):
		options.append(-1)
	if lane < LANES.size() - 1 and _lane_is_free(lane + 1):
		options.append(1)
	if options.is_empty():
		will_change = false                     # boxed in, just drive on
		return
	dir = options.pick_random()
	target_lane = lane + dir
	state = State.SIGNALING
	timer = SIGNAL_TIME
	blink_clock = 0.0


func _start_change() -> void:
	if not _lane_is_free(target_lane):          # someone got in the way: cancel
		target_lane = lane
		state = State.DONE
		_lamps_off()
		return
	state = State.CHANGING
	from_x = position.x
	change_t = 0.0


func _lane_is_free(l: int) -> bool:
	for node in get_parent().get_children():
		var other := node as TrafficCar
		if other == null or other == self:
			continue
		if other.lane == l or other.target_lane == l:
			if absf(other.position.y - position.y) < other.half_size.y + half_size.y + 120.0:
				return false
	return true


func _blink(delta: float) -> void:
	blink_clock += delta
	var on := int(blink_clock / BLINK_HALF_PERIOD) % 2 == 0
	blink_left.visible = on and dir < 0         # screen-left lamp when moving left
	blink_right.visible = on and dir > 0


func _lamps_off() -> void:
	blink_left.visible = false
	blink_right.visible = false
