class_name PlayerCar
extends Node2D
## Player car: steering, swinging headlights, and the FLY ability.
## Scene needed: Player (this script) with ONE child, a Sprite2D named Body (scale 0.5).
## Lights, wings, shadow and underglow are all created here in code.
## Flying is a 2D illusion: the car grows, wings unfold, a shadow stays on the road,
## and while it is "airborne" main.gd skips collisions.

const CONE: Texture2D = preload("res://Assets/light_cone.png")
const WING: Texture2D = preload("res://Assets/car_wing.png")
const BEAM_COLOR := Color(1.0, 0.95, 0.8)
const LAMP := Vector2(16.0, -46.0)          # headlamp: x is +/-, y is toward the nose
const WING_ROOT := Vector2(20.0, 6.0)       # where a wing attaches to the body (x is +/-)
const WING_IMG_ROOT_Y := 46.0               # wing png: root is on the left edge at this y
const AIR_THRESHOLD := 0.35                 # above this altitude the car is untouchable
const FLY_KEYS := [KEY_SPACE, KEY_UP, KEY_W]
const CYAN := Color(0.1, 0.9, 1.0)

@export var steer_speed := 420.0
@export var steer_smoothing := 9.0
@export var min_x := 96.0
@export var max_x := 624.0
@export var body_tilt := 0.18
@export var beam_swing := 0.45
@export var beam_smoothing := 7.0
@export var beam_energy := 1.8
@export var inside_boost := 0.5

@export_group("Flying")
@export var fly_drain := 0.28               # energy per second while flying (full bar ~3.6 s)
@export var fly_recharge := 0.16            # energy per second while on the ground (~6 s)
@export var fly_min_to_start := 0.2         # need this much energy to take off
@export var takeoff_rate := 3.0             # altitude per second going up
@export var land_rate := 2.5                # altitude per second coming down
@export var fly_scale := 1.28               # car size at full altitude
@export var fly_tilt_boost := 1.8           # wings make the bank steeper

var steer := 0.0
var beam_angle := 0.0
var alive := true

var energy := 1.0                           # 0..1, shown in the fly bar
var flying := false                         # fly key is being honoured
var exhausted := false                      # ran dry: recharge until fly_min_to_start
var alt := 0.0                              # 0 = on the road, 1 = full height
var landing_blocked := false                # set by main: a car is under us, don't touch down
var fly_lock := true                        # key must be released once before flying works

var left_light: PointLight2D
var right_light: PointLight2D
var shadow: Sprite2D
var wing_l: Sprite2D
var wing_r: Sprite2D
var glow: PointLight2D

@onready var body: Sprite2D = $Body

var airborne: bool:
	get: return alt > AIR_THRESHOLD


func _ready() -> void:
	left_light = _get_or_make_light("LeftLight", -1.0)
	right_light = _get_or_make_light("RightLight", 1.0)
	_build_flight_nodes()


func _build_flight_nodes() -> void:
	# Order matters: shadow, then wings, then the Body (drawn last = on top).
	shadow = Sprite2D.new()
	shadow.texture = body.texture
	shadow.modulate = Color(0.0, 0.0, 0.0, 0.0)
	shadow.scale = body.scale
	add_child(shadow)
	move_child(shadow, 0)

	wing_l = _make_wing(-1.0)
	wing_r = _make_wing(1.0)
	move_child(wing_l, 1)
	move_child(wing_r, 2)

	# Cyan underglow: a soft radial light that tints the road under the car.
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	glow = PointLight2D.new()
	glow.texture = tex
	glow.color = CYAN
	glow.energy = 0.0
	glow.texture_scale = 1.3
	add_child(glow)


func _make_wing(side: float) -> Sprite2D:
	var w := Sprite2D.new()
	w.texture = WING
	w.centered = false
	w.offset = Vector2(0.0, -WING_IMG_ROOT_Y)     # the root point becomes the node's origin
	w.visible = false
	add_child(w)
	w.set_meta("side", side)
	return w


func _get_or_make_light(node_name: String, side: float) -> PointLight2D:
	var existing := get_node_or_null(node_name) as PointLight2D
	if existing != null:
		return existing
	var light := PointLight2D.new()
	light.name = node_name
	light.texture = CONE
	light.color = BEAM_COLOR
	light.energy = beam_energy
	light.position = Vector2(side * LAMP.x, LAMP.y)
	# The cone's narrow tip is the bottom-centre of the image. Shifting the texture
	# up by half its height puts that tip on the lamp, so the beam pivots around it.
	light.offset = Vector2(0.0, -CONE.get_height() * 0.5)
	add_child(light)
	return light


## Called by main when a run starts: the Space press that started the game must not fly.
func begin_run() -> void:
	fly_lock = true
	energy = 1.0
	exhausted = false


func _process(delta: float) -> void:
	if not alive:
		return

	var target := _read_steer()
	steer = lerpf(steer, target, 1.0 - exp(-steer_smoothing * delta))
	position.x = clampf(position.x + steer * steer_speed * delta, min_x, max_x)
	rotation = steer * body_tilt * lerpf(1.0, fly_tilt_boost, alt)

	_update_flight(delta)
	_apply_flight_visuals()

	# Beams follow the INPUT, not the car, so they lead the turn.
	beam_angle = lerpf(beam_angle, target * beam_swing, 1.0 - exp(-beam_smoothing * delta))
	left_light.rotation = beam_angle
	right_light.rotation = beam_angle

	# Inside light gets brighter, outside one dims a little.
	var lean := clampf(beam_angle / beam_swing, -1.0, 1.0)
	left_light.energy = beam_energy * (1.0 + inside_boost * maxf(-lean, 0.0) - 0.25 * maxf(lean, 0.0))
	right_light.energy = beam_energy * (1.0 + inside_boost * maxf(lean, 0.0) - 0.25 * maxf(-lean, 0.0))


func _update_flight(delta: float) -> void:
	var held := _fly_held()
	if not held:
		fly_lock = false

	var wants := held and not fly_lock
	if wants and not flying:
		wants = energy >= fly_min_to_start and not exhausted
	flying = wants

	if flying:
		energy = maxf(energy - fly_drain * delta, 0.0)
		if energy <= 0.0:                      # ran dry: drop, and wait for the key to be released
			flying = false
			exhausted = true
			fly_lock = true
	elif alt <= AIR_THRESHOLD or landing_blocked:
		pass                                   # no recharge while still in the air
	if not flying and alt < 0.05:
		energy = minf(energy + fly_recharge * delta, 1.0)
		if exhausted and energy >= fly_min_to_start:
			exhausted = false

	if flying:
		alt = minf(alt + takeoff_rate * delta, 1.0)
	else:
		var was_alt := alt
		alt = maxf(alt - land_rate * delta, 0.0)
		# Something is underneath: keep hovering until it passes. Only if we were ALREADY
		# in the air; a car on the ground must never lift us off the road.
		if landing_blocked and was_alt > AIR_THRESHOLD:
			alt = maxf(alt, AIR_THRESHOLD + 0.02)


func _fly_held() -> bool:
	for k in FLY_KEYS:
		if Input.is_physical_key_pressed(k):
			return true
	return false


func _apply_flight_visuals() -> void:
	var e := ease(alt, 0.6)
	var s := lerpf(1.0, fly_scale, e)
	body.scale = Vector2(0.5, 0.5) * s

	# Shadow stays on the road: it slides away from the car and fades in as we climb.
	shadow.scale = Vector2(0.5, 0.5) * lerpf(1.0, 0.92, e)
	shadow.position = Vector2(14.0, 20.0) * e
	shadow.modulate.a = 0.38 * e

	# Wings unfold sideways from the body.
	for w in [wing_l, wing_r]:
		var side: float = w.get_meta("side")
		w.visible = alt > 0.02
		w.position = Vector2(side * WING_ROOT.x * s, WING_ROOT.y * s)
		w.scale = Vector2(side * 0.5 * s * e, 0.5 * s)
		w.modulate.a = clampf(alt * 2.5, 0.0, 1.0)

	glow.energy = 1.1 * e
	glow.position = Vector2(0.0, 8.0)

	# Lamps ride the nose as the car grows.
	left_light.position = Vector2(-LAMP.x, LAMP.y) * s
	right_light.position = Vector2(LAMP.x, LAMP.y) * s


func _read_steer() -> float:
	var s := Input.get_axis("ui_left", "ui_right")
	if Input.is_physical_key_pressed(KEY_A):
		s -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		s += 1.0
	return clampf(s, -1.0, 1.0)


func crash() -> void:
	alive = false
	flying = false
	# Headlights die out and the car spins a little from the impact.
	var tw := create_tween().set_parallel(true)
	tw.tween_property(left_light, "energy", 0.0, 0.5)
	tw.tween_property(right_light, "energy", 0.0, 0.5)
	tw.tween_property(glow, "energy", 0.0, 0.3)
	tw.tween_property(self, "rotation", rotation + randf_range(-0.6, 0.6), 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
