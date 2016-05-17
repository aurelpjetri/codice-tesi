extensions [nw table]

;; Beacons are nodes in our network that comunicate
;; the shortest path to the movers that need to
;; reach their destination
breed [beacons beacon]
;; These turtles are used for street drawing
breed [street-drawers street-drawer]

;; Movers are turtles that need to reach certain destinations
breed [movers mover]

;; Streets are links between beacons with certain capacity
undirected-link-breed [streets street]
directed-link-breed [directed-streets directed-street]

movers-own [
  destination-beacon ;; current destination moving towards
  destination-list ;; list of all my locations
  destination-order ;; Table with strategies to calculate my next destination
  destination-reached ;; whether I've reached the current destination
  current-beacon ;; current beacon on my path
  previous-beacon ;; beacon that I'm coming from
  undesired-street ;; street that is not included in my path, since i got stuck there
  speed
  should-move? ;; used when calculating the next patch
  patience ;; for how long can I be stuck before changing my direction
]

streets-own [
  weight
  street-width
]

directed-streets-own [
  weight
  street-width
]

street-drawers-own [
  drawer-destination
  drawer-width
]

beacons-own [
  intersection-width
  intersection-height
  intersection-radius
  interest-point?
  entry-point?
  entry-ratios
  exit-point?
]

;; Patches can be wall so they are now walkable
patches-own [
  wall
]

globals [
  ;; these need to be redefined
  global-crowd-max-at-patch

  ;; global tables
  destination-ordering

  ;; Needed for import to work
  world-offset
  global-street-distance
  global-street-width
  global-non-wall-color
  grid-size
  n-interest-points
  export-filename
]

;; IMPORT AND DEFAULTS
;; ===================

to import
  import-world import-filename
  default-configuration
end



;; GO PROCEDURE
;; ============

to go
  if use-exits = true [ old-movers-leave ]
  if use-entries = true [ new-movers-enter ]
  move
  tick
end

to old-movers-leave
  ask beacons with [exit-point? = true] [
    ask patches in-radius intersection-radius [
      ask movers-here [
        if random-float 1 < exit-ratio and empty? destination-list [ die ] ]
    ]
  ]
end

to new-movers-enter
  ask beacons with [entry-point? = true] [
    ask patches in-radius intersection-radius with [count movers-here < global-crowd-max-at-patch] [
      if random-float 1 < entry-ratio [
        generate-new-mover
      ]
    ]
  ]
end



;; Given a list of behaviours and their probabilities
;; returns a random behaviour wrt to those probabilities
to-report get-random-mover-behaviour [iter-list]
  let random-dice random 100
  let acc 0
  foreach iter-list [
    set acc acc + (item 1 ?)
    if random-dice < acc
      [ report item 0 ? ]
  ]
end

;; MOVE PROCEDURE
;; ==============

;; Just a standard task that calls all the right procedures
to move
  update-path
  update-next-patch
  ask movers with [should-move? = true] [ fd speed ]
  ask movers with [should-move? = false] [ set patience patience - 1]
  ask movers with [patience <= 0] [
    orient-random-mover self
    set patience random (3 + global-patience)
  ]
end

;; Check if I've reached the beacons and update my path,
;; otherwise keep going towards the current-beacon
to update-path
  ask movers [
    let next-beacon current-beacon
    let current-mover self

    ;; have I reached the current beacon?
    ask current-beacon [
      if member? [patch-here] of myself patches in-radius intersection-radius [
        ;; set the previous beacon to the current-one, since we have reached it
        ask myself [set previous-beacon current-beacon]

        ;; Control if this beacon is in my destination list and remove it
        check-if-involuntary-destination current-mover self

        ;; calculate the full path to my destination
        nw:set-context (beacons) ((link-set streets directed-streets) with [self != [undesired-street] of current-mover])
        let full-path nw:turtles-on-weighted-path-to [destination-beacon] of myself "weight"

        ;; If there are more than one beacon in the path I haven't reached my destination
        ;; nw-path returns with the current beacon, so we take only the tail of the list
        if not empty? but-first full-path
          [ ask myself [set current-beacon item 1 full-path] ]

        ;; if only one item is present in the weighted path
        ;; a destination-beacon has been reached, here we check with if for
        ;; more security
        if self = [destination-beacon] of myself
          [
            ;; remove the current destination-beacon from this list
            ask current-mover [
              ifelse not empty? destination-list
                ;;[ run table:get destination-ordering destination-order]
			    [set-destination-min-distance]
                [ set destination-beacon one-of beacons with [exit-point? = true]]
              set color [color] of destination-beacon
          ] ]
      ]
    ]
    face current-beacon
  ]
end


to check-if-involuntary-destination [agent tmp-beacon]
  if member? tmp-beacon [destination-list] of agent [
    let new-destination-list filter [? != tmp-beacon] [destination-list] of agent
    ask agent [set destination-list new-destination-list]
  ]
end

to update-next-patch
  ask movers with [destination-reached = false] [
    set should-move? false

    ;; get an ordered list of patches where i could move
    let oriented-list oriented-list-of-patches neighbors4 in-cone 2 180 with [wall = false]
    foreach reverse oriented-list [
      if free-mover-patch ? [
        face ?
        set should-move? true
      ]
    ]
  ]
end

;; Returns a list of patches that are ordered by in ascending order
;; wrt the difference between movers heading and the position of
;; the patch, i.e. returns an ordered list of the best patches to
;; visit
to-report oriented-list-of-patches [reachable-patches]
  report sort-on [abs subtract-headings [heading] of myself (towards myself + 180) mod 360] reachable-patches
end

;; Reports whether the patch passed has actually enough free space
to-report free-mover-patch [mover-patch]
  ifelse global-crowd-max-at-patch > [count movers-here] of mover-patch
    [report true]
    [report false]
end

;; ==================================================================
;; This is called when a mover gets blocked, he should in some way
;; backtrack to the previous beacon and try to find a path that
;; does not include the current-beacon
;; ==================================================================
to orient-random-mover [random-mover]
  ask previous-beacon [
    let possible-undesired-street one-of my-streets with [other-end = [current-beacon] of random-mover]
    nw:set-context (beacons) ((link-set streets directed-streets) with [self != possible-undesired-street])
    let full-path nw:turtles-on-weighted-path-to [destination-beacon] of myself "weight"

    if not empty? full-path [
      ask myself [
        ;; if there is another way of reaching the current destination
        ;; then put the current street as undesirable
        set undesired-street possible-undesired-street
        ;; if my previous beacon is different from the current and destination I should move
        ;; towards it => (item 0 full-path), otherwise there will be more than one element
        ;; in the full-path and it is more convenient to move towards the (item 1 full-path)
        ifelse current-beacon != previous-beacon and previous-beacon != destination-beacon
          [set current-beacon item 0 full-path]
          [set current-beacon item 1 full-path]
      ]
    ]
  ]
end

;; ==================================================================
;; DESTINATION STRATEGIES
;; ==================================================================
;; Called inside the mover context

to set-destination-min-distance
  let origin-beacon current-beacon
  set destination-list sort-by [
    [nw:weighted-distance-to origin-beacon "weight"] of ?1 <
      [nw:weighted-distance-to origin-beacon "weight"] of ?2 ] destination-list
  set destination-beacon item 0 destination-list
end

to set-destination-ordered-list
  set destination-beacon item 0 destination-list
end

;; ==================================================================
;; SOME CONTROL PROCEDURES
;; ==================================================================
to toggle-graph-view
  ask streets [set hidden? not hidden?]
  ask beacons with [interest-point? = false] [set hidden? not hidden?]
end

to change-poi
  toggle-graph-view
  let poi-die one-of beacons with [interest-point? = true]
  ask one-of beacons with [interest-point? = false and entry-point? = false and exit-point? = false] [
    set interest-point? true
  ]
  ask poi-die [set interest-point? false]
  toggle-graph-view
end

to-report get-interest-beacons [coor-list]
  let a map [item 0 sort ?] (map [ beacons-on patch (item 0 ?) (item 1 ?) ] )
  let list-of-beacons []
  foreach [ [10 10] [10 25] [40 40] ] [
    set list-of-beacons lput (item 0 sort (beacons-on patch (item 0 ?) (item 1 ?))) list-of-beacons
  ]
  report list-of-beacons
end

;; =================== INIZIO



to default-configuration
  set-default-shape beacons "box"
  set-default-shape movers "circle"
  set global-crowd-max-at-patch 5
 
  set behaviors-map table:make
  table:put behaviors-list 0 get-interest-beacons [ [0 10] ]
  table:put behaviors-list 1 get-interest-beacons [ [10 10] ]
end
