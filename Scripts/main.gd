extends Node2D
## Drive It! main script: road, traffic, score + difficulty, start screen, pause menu, crash.

const TRAFFIC_SCENE: PackedScene = preload("res://Scenes/traffic_car.tscn")
const UI_FONT: Font = preload("res://Assets/PressStart2P.ttf")
const BOX_TEXTURE: Texture2D = preload("res://Assets/score_box.png")
const MUSIC: AudioStream = preload("res://Assets/Audio/music.ogg")
const CRASH_SND: AudioStream = preload("res://Assets/Audio/crash.wav")
const FLY_LOOP: AudioStream = preload("res://Assets/Audio/fly_loop.wav")
const TAKEOFF_SND: AudioStream = preload("res://Assets/Audio/takeoff.wav")

const ROAD_TILE_HEIGHT := 512.0
const DISTANCE_PER_POINT := 10.0      # px of road per score point
const YELLOW := Color(1.0, 0.76, 0.1)
const GREY := Color(0.75, 0.75, 0.8)

# ---- Difficulty: everything here ramps up with the score ----
const SCORE_PER_LEVEL := 800          # score needed for each new level
const MAX_LEVEL := 9                  # top difficulty (shown as LEVEL 10)
const IDLE_SPEED := 180.0             # road speed on the start screen / when a run begins
const START_SPEED := 300.0            # road speed at level 1
const SPEED_PER_LEVEL := 90.0         # +90 per level, about 1110 at the top
const ACCELERATION := 60.0            # how fast speed eases toward the level's speed
const SPAWN_DIST_START := 600.0       # px of road between spawns at level 1 (sparse)
const SPAWN_DIST_END := 200.0         # same, at the top level (busy)
const TRAFFIC_SPEED_BOOST := 0.10     # oncoming cars are 10% faster per level

# ---- Crash ----
const PLAYER_HALF := Vector2(26.0, 48.0)   # player hitbox half-size (the sprite is 32 x 56)
const HIT_FORGIVENESS := 0.85              # traffic hitboxes are shrunk to this fraction
const SHAKE_POWER := 22.0                  # screen shake strength in px
const SHAKE_DECAY := 45.0                  # px of shake lost per second
const RESTART_DELAY := 0.85                # seconds before restart is allowed
const SAVE_PATH := "user://drive_it.cfg"   # best score is stored here
const LANDING_MARGIN := 40.0               # don't touch down if a car is this close to our box

# ---- Fly bar (HUD box under the score box) ----
const FLY_SEGMENTS := 16
const FLY_BOX_POS := Vector2(744.0, 224.0)
const FLY_BOX_SIZE := Vector2(232.0, 132.0)
const FLY_LOW := 0.25                      # below this the bar turns pink-red

# ---- Audio (volumes in dB, 0 = full) ----
const MUSIC_DB_MENU := -16.0               # start screen
const MUSIC_DB_PLAY := -9.0                # during a run
const MUSIC_DB_PAUSE := -22.0              # ducked while paused
const CRASH_DB := -2.0
const FLY_DB := -6.0
const TAKEOFF_DB := -5.0

# ---- Score box layout (the labels are placed by code, edit the numbers here) ----
const BOX_PAD_X := 16.0               # space between the box border and the text
const BOX_PAD_Y := 24.0               # space above the first row / below the last row

# Survives a scene reload: restarting skips the start screen.
static var skip_start := false

var speed := IDLE_SPEED
var distance := 0.0
var score := 0
var best_score := 0
var level := 0                        # 0-based inside the code, shown as level + 1
var road_offset := 0.0
var spawn_in := 1.0
var last_lane := 2
var started := false                  # false = start screen
var paused := false
var game_over := false
var can_restart := false
var shake := 0.0
var fly_segs: Array[ColorRect] = []
var fly_status: Label
var music_player: AudioStreamPlayer
var crash_player: AudioStreamPlayer
var fly_player: AudioStreamPlayer
var takeoff_player: AudioStreamPlayer
var was_airborne := false

var camera: Camera2D                  # created in _ready (used for screen shake)
var flash: ColorRect                  # white flash on impact
var start_root: Control               # start screen
var start_best: Label
var start_hint: Label
var pause_root: Control               # pause menu
var pause_score: Label
var pause_best: Label
var over_root: Control                # game-over screen
var over_score: Label
var over_best: Label
var over_note: Label
var over_hint: Label

@onready var road: Sprite2D = $Road
@onready var traffic_root: Node2D = $Traffic
@onready var player: PlayerCar = $Player
@onready var score_label: Label = $HUD/ScoreBox/ScoreLabel
@onready var level_label: Label = $HUD/ScoreBox/LevelLabel


func _ready() -> void:
	score_label.text = "%06d" % 0
	level_label.text = "LEVEL 1"
	_layout_score_box()
	best_score = _load_best()

	camera = Camera2D.new()
	camera.position = Vector2(500.0, 480.0)     # centre of the 1000 x 960 screen
	add_child(camera)
	camera.make_current()

	_build_screens()
	_build_audio()                              # before the fly bar: it updates the wind sound
	_build_fly_box()

	if skip_start:                              # restarted from a crash or the pause menu
		skip_start = false
		_start_game()
	else:                                       # fresh launch: car parked, road rolling
		player.process_mode = Node.PROCESS_MODE_DISABLED
		music_player.volume_db = MUSIC_DB_MENU
		start_best.text = "BEST %06d" % best_score
		start_root.show()
		_blink(start_hint)


func _process(delta: float) -> void:
	delta = minf(delta, 0.033)       # a lag spike must never teleport cars through the player
	_update_shake(delta)
	if game_over or paused:
		return

	if not started:                  # start screen: only the road moves
		_scroll_road(delta)
		return

	# Speed eases toward whatever the current level asks for.
	speed = move_toward(speed, START_SPEED + level * SPEED_PER_LEVEL, ACCELERATION * delta)
	distance += speed * delta
	score = int(distance / DISTANCE_PER_POINT)
	_update_level()
	_scroll_road(delta)

	_update_traffic(delta)
	if game_over:                    # _update_traffic may have just crashed us
		return
	_spawn_traffic(delta)

	score_label.text = "%06d" % score
	_update_fly_bar()


func _scroll_road(delta: float) -> void:
	road_offset = fposmod(road_offset - speed * delta, ROAD_TILE_HEIGHT)
	road.region_rect = Rect2(0, road_offset, 720, 960)


# ------------------------------------------------------- start / pause / restart
func _start_game() -> void:
	started = true
	start_root.hide()
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.begin_run()
	create_tween().tween_property(music_player, "volume_db", MUSIC_DB_PLAY, 0.8)   # music swells in
	spawn_in = 1.5                   # a moment of empty road before the first car


func _pause() -> void:
	paused = true
	_set_world_active(false)
	pause_score.text = "SCORE %06d" % score
	pause_best.text = "BEST %06d" % maxi(best_score, score)
	pause_root.show()
	music_player.volume_db = MUSIC_DB_PAUSE
	fly_player.stream_paused = true


func _resume() -> void:
	paused = false
	_set_world_active(true)
	pause_root.hide()
	music_player.volume_db = MUSIC_DB_PLAY
	fly_player.stream_paused = false


func _set_world_active(active: bool) -> void:
	# Disabling a node also freezes its children (cars, lights) and their tweens.
	var mode := Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	traffic_root.process_mode = mode
	player.process_mode = mode


func _restart() -> void:
	skip_start = true                # the new run starts straight away
	get_tree().reload_current_scene()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	var click := event as InputEventMouseButton
	var key_down := key != null and key.pressed and not key.echo
	var click_down := click != null and click.pressed

	if not started:                                          # start screen: Space / Enter
		if key_down and key.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_start_game()
		return
	if game_over:                                            # crash screen
		if can_restart and ((key_down and key.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_R]) or click_down):
			_restart()
		return
	if paused:                                               # pause menu
		if key_down and key.keycode in [KEY_ESCAPE, KEY_P]:
			_resume()
		elif key_down and key.keycode == KEY_R:
			_restart()
		return
	if key_down and key.keycode in [KEY_ESCAPE, KEY_P]:      # playing
		_pause()


# ------------------------------------------------------------------ score box
func _layout_score_box() -> void:
	# Three rows (SCORE / number / LEVEL): centred, evenly spaced, padded from the border.
	var box: Control = $HUD/ScoreBox
	var title: Label = box.get_node_or_null("TitleLabel")
	var first_y := BOX_PAD_Y + 8.0                 # centre of the first row
	var last_y := box.size.y - BOX_PAD_Y - 8.0     # centre of the last row
	_place_row(title, first_y, 32.0)
	_place_row(score_label, (first_y + last_y) * 0.5, 40.0)
	_place_row(level_label, last_y, 32.0)


func _place_row(label: Label, center_y: float, height: float) -> void:
	if label == null:
		return
	var box: Control = label.get_parent()
	label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.position = Vector2(BOX_PAD_X, center_y - height * 0.5)
	label.size = Vector2(box.size.x - 2.0 * BOX_PAD_X, height)


func _update_level() -> void:
	var new_level := mini(floori(float(score) / SCORE_PER_LEVEL), MAX_LEVEL)
	if new_level == level:
		return
	level = new_level
	level_label.text = "LEVEL %d" % (level + 1)
	# Little pulse so the player notices the level-up.
	level_label.pivot_offset = level_label.size * 0.5
	var tw := create_tween()
	tw.tween_property(level_label, "scale", Vector2(1.35, 1.35), 0.12)
	tw.tween_property(level_label, "scale", Vector2.ONE, 0.25)


# -------------------------------------------------------------------- traffic
func _update_traffic(delta: float) -> void:
	var blocked := false
	for node in traffic_root.get_children():
		var car := node as TrafficCar
		car.player_speed = speed
		car.position.y += (speed + car.own_speed) * delta     # oncoming: speeds add up
		if not player.airborne and _overlaps(car, 0.0):       # flying = no collisions
			_crash(car)
			return
		if _overlaps(car, LANDING_MARGIN):
			blocked = true
		if car.position.y - car.half_size.y > 1100.0:
			car.queue_free()
	player.landing_blocked = blocked                          # keeps us hovering over a car


func _overlaps(car: TrafficCar, margin: float) -> bool:
	# Box vs box. Traffic hitboxes are shrunk a little so near-misses feel fair.
	var dx := absf(car.position.x - player.position.x)
	var dy := absf(car.position.y - player.position.y)
	return dx < PLAYER_HALF.x + car.half_size.x * HIT_FORGIVENESS + margin \
		and dy < PLAYER_HALF.y + car.half_size.y * HIT_FORGIVENESS + margin


func _hits_player(car: TrafficCar) -> bool:
	return _overlaps(car, 0.0)


func _spawn_traffic(delta: float) -> void:
	spawn_in -= delta
	if spawn_in > 0.0:
		return

	# Never fill the entry band, so there is always a gap to drive through.
	var max_in_band := mini(2 + int(level / 3.0), 4)
	var in_band := 0
	for node in traffic_root.get_children():
		if node.position.y < 260.0:
			in_band += 1
	if in_band >= max_in_band:
		return

	var lane_count := TrafficCar.LANES.size()
	var lane := randi() % lane_count
	if lane == last_lane and randf() < 0.6:
		lane = (lane + 1 + randi() % (lane_count - 1)) % lane_count

	var type_index := _pick_type()
	var half: Vector2 = TrafficCar.TYPES[type_index].half
	var spawn_y := -(half.y + 30.0)

	# That lane's entrance is still occupied: try again next frame.
	for node in traffic_root.get_children():
		var other := node as TrafficCar
		if (other.lane == lane or other.target_lane == lane) \
				and other.position.y - other.half_size.y < spawn_y + half.y + 60.0:
			return

	last_lane = lane
	var car: TrafficCar = TRAFFIC_SCENE.instantiate()
	car.position.y = spawn_y
	traffic_root.add_child(car)
	car.setup(type_index, lane)
	car.own_speed *= 1.0 + TRAFFIC_SPEED_BOOST * level     # faster traffic at higher levels

	# Higher level = shorter gap between spawns = busier road.
	var gap := lerpf(SPAWN_DIST_START, SPAWN_DIST_END, float(level) / MAX_LEVEL)
	spawn_in = randf_range(0.8, 1.25) * gap / speed


func _pick_type() -> int:
	var r := randf()
	if r < 0.62:
		return randi() % 6      # cars
	if r < 0.78:
		return 6                # pickup
	if r < 0.90:
		return 7                # small box truck
	if r < 0.96:
		return 8                # big box truck
	return 9                    # semi


# --------------------------------------------------------------------- crash
func _crash(car: TrafficCar) -> void:
	game_over = true
	can_restart = false
	player.crash()
	fly_player.stop()
	crash_player.play()
	create_tween().tween_property(music_player, "volume_db", -40.0, 0.9)        # music dies out
	for node in traffic_root.get_children():
		node.set_process(false)                 # freeze every car where it is

	# Impact effects
	shake = SHAKE_POWER
	_spawn_sparks((player.position + car.position) * 0.5)
	flash.color.a = 0.75
	create_tween().tween_property(flash, "color:a", 0.0, 0.4)

	# Best score
	var new_best := score > best_score
	if new_best:
		best_score = score
		_save_best(best_score)
	over_score.text = "SCORE %06d" % score
	over_best.text = "BEST %06d" % best_score
	over_note.text = "NEW BEST!" if new_best else ""

	# Short pause, then the game-over box fades in, then restart becomes possible.
	await get_tree().create_timer(0.5).timeout
	_show_game_over()
	await get_tree().create_timer(RESTART_DELAY - 0.5).timeout
	can_restart = true


func _update_shake(delta: float) -> void:
	if shake > 0.0:
		shake = maxf(shake - SHAKE_DECAY * delta, 0.0)
		camera.offset = Vector2(randf_range(-shake, shake), randf_range(-shake, shake))
	else:
		camera.offset = Vector2.ZERO


func _spawn_sparks(at: Vector2) -> void:
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 1.0])
	fade.colors = PackedColorArray([Color(1.0, 0.9, 0.35, 1.0), Color(1.0, 0.4, 0.1, 0.0)])
	var p := CPUParticles2D.new()
	p.position = at
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 40
	p.lifetime = 0.6
	p.spread = 180.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 120.0
	p.initial_velocity_max = 420.0
	p.scale_amount_min = 3.0
	p.scale_amount_max = 8.0
	p.color_ramp = fade
	$HUD.add_child(p)                           # HUD layer = not darkened by the night tint
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)


func _show_game_over() -> void:
	over_root.modulate.a = 0.0
	over_root.show()
	create_tween().tween_property(over_root, "modulate:a", 1.0, 0.25)
	_blink(over_hint)


func _blink(label: Label) -> void:
	var tw := create_tween().set_loops()
	tw.tween_property(label, "modulate:a", 0.25, 0.5)
	tw.tween_property(label, "modulate:a", 1.0, 0.5)


# ------------------------------------------------- start / pause / crash screens
func _build_screens() -> void:
	flash = ColorRect.new()
	flash.color = Color(1.0, 1.0, 1.0, 0.0)
	flash.size = Vector2(720.0, 960.0)          # covers the road area only
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$HUD.add_child(flash)

	# START SCREEN
	var s := _make_screen("DRIVE IT!", YELLOW, 0.3)     # lighter dimming: the car and road stay visible
	start_root = s[0]
	var sb: Control = s[1]
	start_best = _box_label(sb, "", 20, Color.WHITE, 118.0, 32.0)
	_box_label(sb, "A / D OR ARROWS TO STEER", 16, GREY, 172.0, 28.0)
	_box_label(sb, "ESC OR P TO PAUSE", 16, GREY, 206.0, 28.0)
	_box_label(sb, "HOLD SPACE TO FLY", 16, Color(0.1, 0.9, 1.0), 234.0, 28.0)
	start_hint = _box_label(sb, "PRESS SPACE TO START", 16, Color.WHITE, 268.0, 32.0)

	# PAUSE MENU
	var p := _make_screen("PAUSED", YELLOW)
	pause_root = p[0]
	var pb: Control = p[1]
	pause_score = _box_label(pb, "", 20, Color.WHITE, 118.0, 32.0)
	pause_best = _box_label(pb, "", 20, YELLOW, 164.0, 32.0)
	_box_label(pb, "ESC OR P  -  RESUME", 16, Color.WHITE, 222.0, 28.0)
	_box_label(pb, "R  -  RESTART", 16, Color.WHITE, 262.0, 28.0)

	# CRASH SCREEN
	var o := _make_screen("CRASH!", Color(1.0, 0.35, 0.25))
	over_root = o[0]
	var ob: Control = o[1]
	over_score = _box_label(ob, "", 20, Color.WHITE, 118.0, 32.0)
	over_best = _box_label(ob, "", 20, YELLOW, 164.0, 32.0)
	over_note = _box_label(ob, "", 16, YELLOW, 208.0, 28.0)
	over_hint = _box_label(ob, "PRESS SPACE TO RESTART", 16, Color.WHITE, 268.0, 32.0)


func _make_screen(title: String, title_color: Color, dim_alpha: float = 0.55) -> Array:
	# A dimmed road area with a score-box-style panel and a big title. Returns [screen, box].
	var screen := Control.new()
	screen.size = Vector2(720.0, 960.0)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.visible = false
	$HUD.add_child(screen)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, dim_alpha)
	dim.size = screen.size
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(dim)

	var box := NinePatchRect.new()
	box.texture = BOX_TEXTURE
	box.patch_margin_left = 8
	box.patch_margin_top = 8
	box.patch_margin_right = 8
	box.patch_margin_bottom = 8
	box.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.position = Vector2(110.0, 300.0)
	box.size = Vector2(500.0, 330.0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(box)

	_box_label(box, title, 40, title_color, 34.0, 56.0)
	return [screen, box]


func _box_label(parent: Control, text: String, font_size: int, color: Color, y: float, h: float) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", UI_FONT)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = Vector2(16.0, y)
	l.size = Vector2(parent.size.x - 32.0, h)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


# ------------------------------------------------------------------ fly bar
func _build_fly_box() -> void:
	var box := NinePatchRect.new()
	box.texture = BOX_TEXTURE
	box.patch_margin_left = 8
	box.patch_margin_top = 8
	box.patch_margin_right = 8
	box.patch_margin_bottom = 8
	box.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.position = FLY_BOX_POS
	box.size = FLY_BOX_SIZE
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$HUD.add_child(box)

	var title := _box_label(box, "FLY", 20, Color.WHITE, 22.0, 28.0)
	title.position.x = BOX_PAD_X - 16.0 + 16.0

	var seg_w := 10.0
	var gap := 2.0
	var total := FLY_SEGMENTS * seg_w + (FLY_SEGMENTS - 1) * gap
	var x0 := (box.size.x - total) * 0.5
	for i in FLY_SEGMENTS:
		var r := ColorRect.new()
		r.position = Vector2(x0 + i * (seg_w + gap), 62.0)
		r.size = Vector2(seg_w, 26.0)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(r)
		fly_segs.append(r)
	fly_status = _box_label(box, "", 12, GREY, 98.0, 20.0)
	_update_fly_bar()


func _fly_color(i: int, low: bool) -> Color:
	if low:
		return Color(1.0, 0.3, 0.45).lerp(Color(1.0, 0.55, 0.3), float(i) / FLY_SEGMENTS)
	# Mostly cyan: deep blue at the left, bright cyan in the middle, mint at the right.
	var t := float(i) / (FLY_SEGMENTS - 1)
	if t < 0.35:
		return Color(0.2, 0.45, 1.0).lerp(Color(0.1, 0.9, 1.0), t / 0.35)
	if t < 0.8:
		return Color(0.1, 0.9, 1.0)
	return Color(0.1, 0.9, 1.0).lerp(Color(0.55, 1.0, 0.85), (t - 0.8) / 0.2)


func _update_fly_audio() -> void:
	var a := player.alt
	if a > 0.02:
		if not fly_player.playing:
			fly_player.play()
		fly_player.volume_db = FLY_DB + linear_to_db(clampf(a, 0.001, 1.0))
		fly_player.pitch_scale = 0.8 + 0.35 * a
	elif fly_player.playing:
		fly_player.stop()
	if player.airborne and not was_airborne:
		takeoff_player.play()
	was_airborne = player.airborne


func _make_player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var ap := AudioStreamPlayer.new()
	ap.stream = stream
	ap.volume_db = db
	add_child(ap)
	return ap


func _build_audio() -> void:
	# Looping is set here so the files need no import settings.
	var music: AudioStream = MUSIC               # a plain variable, so the type checks pass
	if music is AudioStreamOggVorbis:
		music.loop = true
	var fly_stream: AudioStream = FLY_LOOP
	var fl := fly_stream as AudioStreamWAV
	if fl != null:
		fl.loop_mode = AudioStreamWAV.LOOP_FORWARD
		fl.loop_begin = 0
		fl.loop_end = int(fl.get_length() * fl.mix_rate)
	music_player = _make_player(MUSIC, MUSIC_DB_MENU)
	crash_player = _make_player(CRASH_SND, CRASH_DB)
	fly_player = _make_player(FLY_LOOP, FLY_DB)
	takeoff_player = _make_player(TAKEOFF_SND, TAKEOFF_DB)
	music_player.play()


func _update_fly_bar() -> void:
	_update_fly_audio()
	var e := player.energy
	var low := e < FLY_LOW or player.exhausted
	for i in fly_segs.size():
		var fill := clampf(e * FLY_SEGMENTS - i, 0.0, 1.0)
		var c := _fly_color(i, low)
		var off := Color(0.1, 0.15, 0.2)
		fly_segs[i].color = off.lerp(c, fill)
	if player.airborne:
		fly_status.text = "FLYING!"
		fly_status.add_theme_color_override("font_color", Color(0.1, 0.9, 1.0))
	elif player.exhausted:
		fly_status.text = "RECHARGING"
		fly_status.add_theme_color_override("font_color", Color(1.0, 0.4, 0.5))
	elif e >= 0.999:
		fly_status.text = "HOLD SPACE"
		fly_status.add_theme_color_override("font_color", GREY)
	else:
		fly_status.text = "CHARGING"
		fly_status.add_theme_color_override("font_color", GREY)


# ------------------------------------------------------------------ best score
func _load_best() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		return int(cfg.get_value("game", "best", 0))
	return 0


func _save_best(value: int) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "best", value)
	cfg.save(SAVE_PATH)
