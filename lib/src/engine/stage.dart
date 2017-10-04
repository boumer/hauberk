import 'package:piecemeal/piecemeal.dart';

import 'ai/flow.dart';
import 'actor.dart';
import 'breed.dart';
import 'fov.dart';
import 'game.dart';
import 'hero/hero.dart';
import 'items/inventory.dart';
import 'items/item.dart';

/// The game's live play area.
class Stage {
  final Game game;

  final _actors = <Actor>[];
  final Fov _fov;
  int _currentActorIndex = 0;

  /// The total number of tiles the [Hero] can explore in the stage.
  int get numExplorable => _numExplorable;
  int _numExplorable;

  int get width => tiles.width;
  int get height => tiles.height;
  Rect get bounds => tiles.bounds;

  Iterable<Actor> get actors => _actors;

  Actor get currentActor => _actors[_currentActorIndex];

  final Array2D<Tile> tiles;

  final _itemsByTile = <Vec, Inventory>{};

  /// A spatial partition to let us quickly locate an actor by tile.
  ///
  /// This is a performance bottleneck since pathfinding needs to ensure it
  /// doesn't step on other actors.
  final Array2D<Actor> _actorsByTile;

  bool _visibilityDirty = true;

  /// Tracks global pathfinding distances to the hero, ignoring other actors.
  Flow _heroPaths;

  Stage(int width, int height, Game game)
      : game = game,
        tiles = new Array2D<Tile>.generated(width, height, () => new Tile()),
        _actorsByTile = new Array2D<Actor>(width, height),
        _fov = new Fov(game);

  Tile operator[](Vec pos) => tiles[pos];

  /// Iterates over every item on the ground on the stage.
  Iterable<Item> get allItems sync* {
    for (var inventory in _itemsByTile.values) {
      yield* inventory;
    }
  }

  Tile get(int x, int y) => tiles.get(x, y);
  void set(int x, int y, Tile tile) => tiles.set(x, y, tile);

  /// Called after the level generator has finished laying out the stage.
  void finishBuild() {
    // Count the explorable tiles. We assume the level is fully reachable, so
    // any traversable tile or tile next to a traversable one is explorable.
    _numExplorable = 0;
    for (var pos in bounds.inflate(-1)) {
      var tile = this[pos];
      if (tile.isTraversable) {
        _numExplorable++;
      } else {
        // See if it's next to an traversable one.
        for (var dir in Direction.all) {
          if (this[pos + dir].isTraversable) {
            _numExplorable++;
            break;
          }
        }
      }
    }

    _fov.refresh(game.hero.pos);
  }

  void addActor(Actor actor) {
    assert(_actorsByTile[actor.pos] == null);

    _actors.add(actor);
    _actorsByTile[actor.pos] = actor;
  }

  /// Called when an [Actor]'s position has changed so the stage can track it.
  void moveActor(Vec from, Vec to) {
    var actor = _actorsByTile[from];
    _actorsByTile[from] = null;
    _actorsByTile[to] = actor;
  }

  void removeActor(Actor actor) {
    assert(_actorsByTile[actor.pos] == actor);

    var index = _actors.indexOf(actor);
    if (_currentActorIndex > index) _currentActorIndex--;
    _actors.removeAt(index);

    if (_currentActorIndex >= _actors.length) _currentActorIndex = 0;

    _actorsByTile[actor.pos] = null;
  }

  void advanceActor() {
    _currentActorIndex = (_currentActorIndex + 1) % _actors.length;
  }

  Actor actorAt(Vec pos) => _actorsByTile[pos];

  void addItem(Item item, Vec pos) {
    // Get the inventory for the tile.
    var inventory = _itemsByTile.putIfAbsent(pos, () => new Inventory(null));
    var result = inventory.tryAdd(item);
    // Inventory is unlimited, so should always succeed.
    assert(result.remaining == 0);
  }

  /// Returns `true` if there is at least one item at [pos].
  bool isItemAt(Vec pos) => _itemsByTile.containsKey(pos);

  /// Gets the [Item]s at [pos].
  Iterable<Item> itemsAt(Vec pos) {
    var inventory = _itemsByTile[pos];
    if (inventory == null) return const [];
    return inventory;
  }

  /// Removes [item] from the stage at [pos].
  ///
  /// It is an error to call this if [item] is not on the ground at [pos].
  void removeItem(Item item, Vec pos) {
    var inventory = _itemsByTile[pos];
    assert(inventory != null);

    inventory.remove(item);

    // Discard empty inventories. Note that [isItemAt] assumes this is done.
    if (inventory.isEmpty) _itemsByTile.remove(pos);
  }

  /// Iterates over every item on the stage and returns the item and its
  /// position.
  void forEachItem(callback(Item item, Vec pos)) {
    _itemsByTile.forEach((pos, inventory) {
      for (var item in inventory) {
        callback(item, pos);
      }
    });
  }

  void dirtyVisibility() {
    _visibilityDirty = true;
  }

  void refreshVisibility(Hero hero) {
    if (_visibilityDirty) {
      _fov.refresh(hero.pos);
      _visibilityDirty = false;
    }
  }

  // TODO: This is hackish and may fail to terminate.
  // TODO: Consider flyable tiles for flying monsters.
  /// Selects a random passable tile that does not have an [Actor] on it.
  Vec findOpenTile() {
    while (true) {
      var pos = rng.vecInRect(bounds);

      if (!this[pos].isWalkable) continue;
      if (actorAt(pos) != null) continue;

      return pos;
    }
  }

  /// Gets the number of tiles to walk from [pos] to the [Hero]'s current
  /// position taking into account which tiles are traversable.
  int getHeroDistanceTo(Vec pos) {
    _refreshDistances();
    return _heroPaths.getDistance(pos);
  }

  /// Randomly selects an open tile in the stage. Makes [tries] attempts and
  /// chooses the one most distance from some point. Assumes that [scent2] has
  /// been filled with the distance information for the target point.
  ///
  /// This is used during level creation to place stronger [Monster]s and
  /// better treasure farther from the [Hero]'s starting location.
  Vec findDistantOpenTile(int tries) {
    _refreshDistances();

    var bestDistance = -1;
    var best;

    for (var i = 0; i < tries; i++) {
      var pos = findOpenTile();
      var distance = _heroPaths.getDistance(pos);
      if (distance > bestDistance) {
        best = pos;
        bestDistance = distance;
      }
    }

    return best;
  }

  // TODO: Remove this and use encounters instead.
  void spawnMonster(Breed breed, Vec pos) {
    var monsters = <Actor>[];

    var count = rng.triangleInt(breed.numberInGroup, breed.numberInGroup ~/ 2);

    addMonster(Vec pos) {
      var monster = breed.spawn(game, pos);
      addActor(monster);
      monsters.add(monster);
    }

    // Place the first monster.
    addMonster(pos);

    // If the monster appears in groups, place the rest of the groups.
    for (var i = 1; i < count; i++) {
      // Find every open tile that's neighboring a monster in the group.
      var open = <Vec>[];
      for (var monster in monsters) {
        for (var dir in Direction.all) {
          var neighbor = monster.pos + dir;
          if (this[neighbor].isWalkable && (actorAt(neighbor) == null)) {
            open.add(neighbor);
          }
        }
      }

      if (open.length == 0) {
        // We filled the entire reachable area with monsters, so give up.
        break;
      }

      addMonster(rng.item(open));
    }
  }

  /// Lazily calculates the paths from every reachable tile to the [Hero]. We
  /// use this to place better and stronger things farther from the Hero. Sound
  /// propagation is also based on this.
  void _refreshDistances() {
    // Don't recalculate if still valid.
    if (_heroPaths != null &&  game.hero.pos == _heroPaths.start) return;

    _heroPaths = new Flow(this, game.hero.pos,
        canOpenDoors: true, canFly: true, ignoreActors: true);
  }
}

class TileType {
  final String name;
  final bool isWalkable;
  final bool isFlyable;
  final bool isExit;
  final appearance;
  TileType opensTo;
  TileType closesTo;

  bool get isTraversable => isWalkable || (opensTo != null);

  TileType(this.name, this.appearance,
      {this.isWalkable, this.isFlyable, this.isExit});
}

class Tile {
  TileType type;
  bool _visible  = false;

  Tile();

  bool get visible => _visible;
  void set visible(bool value) {
    if (value) isExplored = true;
    _visible = value;
  }

  /// Sets the visibility of this tile to [visible].
  ///
  /// Returns `true` if this is the first time the tile has been made visible.
  bool setVisible(bool visible) {
    _visible = visible;

    if (visible && !isExplored) {
      isExplored = true;
      return true;
    }

    return false;
  }

  bool isExplored = false;
  bool get isWalkable => type.isWalkable;
  bool get isTraversable => type.isTraversable;
  bool get isFlyable => type.isFlyable;
  bool get isExit => type.isExit;
}
