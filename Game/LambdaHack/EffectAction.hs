-- | The effectToAction function and all it depends on.
-- This file should not depend on Actions.hs nor ItemAction.hs.
-- TODO: Add an export list and document after it's rewritten according to #17.
module Game.LambdaHack.EffectAction where

-- Cabal
import qualified Paths_LambdaHack as Self (version)

import Control.Monad
import Control.Monad.State hiding (State, state)
import Data.Function
import Data.Version
import Data.Maybe
import qualified Data.List as L
import qualified Data.IntMap as IM
import qualified Data.Set as S
import qualified Data.IntSet as IS

import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Display
import Game.LambdaHack.Draw
import Game.LambdaHack.Grammar
import Game.LambdaHack.Point
import qualified Game.LambdaHack.HighScore as H
import Game.LambdaHack.Item
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Random
import Game.LambdaHack.State
import qualified Game.LambdaHack.Config as Config
import qualified Game.LambdaHack.Effect as Effect
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.DungeonState
import qualified Game.LambdaHack.Color as Color

-- TODO: instead of verbosity return msg components and tailor them outside?
-- TODO: separately define messages for the case when source == target
-- and for the other case; then use the messages outside of effectToAction,
-- depending on the returned bool, perception and identity of the actors.

-- | The source actor affects the target actor, with a given effect and power.
-- The second argument is verbosity of the resulting message.
-- Both actors are on the current level and can be the same actor.
-- The first bool result indicates if the effect was spectacular enough
-- for the actors to identify it (and the item that caused it, if any).
-- The second bool tells if the effect was seen by or affected the party.
effectToAction :: Effect.Effect -> Int -> ActorId -> ActorId -> Int
               -> ActionFrame (Bool, Bool)
effectToAction effect verbosity source target power = do
  sm  <- gets (getActor source)
  tm  <- gets (getActor target)
  per <- getPerception
  pl  <- gets splayer
  s   <- get
  let oldHP = bhp tm
      tloc = bloc tm
  -- The msg describes the target part of the action.
  ((b, msg), frames) <- eff effect verbosity source target power
  if isAHero s source ||
     isAHero s target ||
     pl == source ||
     pl == target ||
     (tloc `IS.member` totalVisible per &&
      bloc sm `IS.member` totalVisible per)
    then do
      -- Party sees or affected, so reported.
      msgAdd msg
      -- Party sees or affected, so show an animation.
      sNew <- get
      let twirlSplash c1 c2 = map (IM.singleton tloc)
            [ Color.AttrChar (Color.Attr Color.BrWhite Color.defBG) '*'
            , Color.AttrChar (Color.Attr c1 Color.defBG) '/'
            , Color.AttrChar (Color.Attr c1 Color.defBG) '-'
            , Color.AttrChar (Color.Attr c1 Color.defBG) '\\'
            , Color.AttrChar (Color.Attr c1 Color.defBG) '|'
            , Color.AttrChar (Color.Attr c1 Color.defBG) '/'
            , Color.AttrChar (Color.Attr c1 Color.defBG) '-'
            , Color.AttrChar (Color.Attr c2 Color.defBG) '\\'
            , Color.AttrChar (Color.Attr c2 Color.defBG) '%'
            , Color.AttrChar (Color.Attr c2 Color.defBG) '%'
            ]
          newHP | not (memActor target sNew) = 0
                | otherwise = bhp $ getActor target sNew
          animNew | newHP >  oldHP = twirlSplash Color.BrBlue Color.Blue
                  | newHP <  oldHP = twirlSplash Color.BrRed  Color.Red
                  | otherwise      = []
      modify (\st@State{sanim} -> st {sanim = sanim ++ animNew})
      return ((b, True), frames)
    else do
      -- Hidden, but if interesting then heard.
      when b $ msgAdd "You hear some noises."
      return ((b, False), frames)

eff :: Effect.Effect -> Int -> ActorId -> ActorId -> Int
    -> ActionFrame (Bool, String)
eff Effect.NoEffect _ _ _ _ = nullEffect
eff Effect.Heal _ _source target power = do
  Kind.COps{coactor=coactor@Kind.Ops{okind}} <- getCOps
  let bhpMax m = maxDice (ahp $ okind $ bkind m)
  tm <- gets (getActor target)
  if bhp tm >= bhpMax tm || power <= 0
    then nullEffect
    else do
      (_, frames) <- focusIfOurs target
      updateAnyActor target (addHp coactor power)  -- TODO: duplicate code in  bhpMax and addHp
      return ((True, actorVerbExtra coactor tm "feel" "better"), frames)
eff (Effect.Wound nDm) verbosity source target power = do
  Kind.COps{coactor} <- getCOps
  n  <- rndToAction $ rollDice nDm
  if n + power <= 0 then nullEffect else do
    (_, frames) <- focusIfOurs target
    pl <- gets splayer
    tm <- gets (getActor target)
    let newHP  = bhp tm - n - power
        killed = newHP <= 0
        msg
          | killed =
            if target == pl
            then ""  -- handled later on in checkPartyDeath
            else if bhp tm == 0
                 then actorVerbExtra coactor tm "drop" "down"  -- TODO: hack:
                 else actorVerb coactor tm "die"  -- for projectiles
          | source == target =  -- a potion of wounding, etc.
            actorVerbExtra coactor tm "feel" "wounded"
          | verbosity <= 0 = ""
          | target == pl =
            actorVerbExtra coactor tm "lose" $
              show (n + power) ++ "HP"
          | otherwise = actorVerbExtra coactor tm "hiss" "in pain"
    updateAnyActor target $ \ m -> m { bhp = newHP }  -- Damage the target.
    if killed
      then do
        -- Perform all the focusing on the actor before he is killed.
        tryIgnore $ getOverConfirm frames
        -- Place the actor's possessions on the map.
        bitems <- gets (getActorItem target)
        modify (updateLevel (dropItemsAt bitems (bloc tm)))
        -- Clean bodies up.
        if target == pl
          then -- Kill the player and check game over.
               checkPartyDeath
          else -- Kill the enemy.
               modify (deleteActor target)
        returnNoFrame (True, msg)
      else return ((True, msg), frames)
eff Effect.Dominate _ source target _power = do
  s <- get
  if not $ isAHero s target
    then do  -- Monsters have weaker will than heroes.
      -- Can't use @focusIfOurs@, because the actor is specifically not ours.
      selectPlayer target
        >>= assert `trueM` (source, target, "player dominates himself")
      -- Prevent AI from getting a few free moves until new player ready.
      updatePlayerBody (\ m -> m { btime = 0})
      -- Display status line and FOV for the newly controlled actor.
      fr <- drawPrompt ColorBW ""
      return ((True, ""), [fr])
    else if source == target
         then do
           lm <- gets levelMonsterList
           lxsize <- gets (lxsize . slevel)
           lysize <- gets (lysize . slevel)
           let cross m = bloc m : vicinityCardinal lxsize lysize (bloc m)
               vis = L.concatMap cross lm
           rememberList vis
           returnNoFrame (True, "A dozen voices yells in anger.")
         else nullEffect
eff Effect.SummonFriend _ source target power = do
  tm <- gets (getActor target)
  s <- get
  ((), frames) <- if isAHero s source
    then summonHeroes (1 + power) (bloc tm)
    else inFrame $ summonMonsters (1 + power) (bloc tm)
  return ((True, ""), frames)
eff Effect.SummonEnemy _ source target power = do
  tm <- gets (getActor target)
  s  <- get
  -- A trick: monster player summons a hero.
  ((), frames) <- if not $ isAHero s source
    then summonHeroes (1 + power) (bloc tm)
    else inFrame $ summonMonsters (1 + power) (bloc tm)
  return ((True, ""), frames)
eff Effect.ApplyPerfume _ source target _ =
  if source == target
  then returnNoFrame (True, "Tastes like water, but with a strong rose scent.")
  else do
    let upd lvl = lvl { lsmell = IM.empty }
    modify (updateLevel upd)
    returnNoFrame (True, "The fragrance quells all scents in the vicinity.")
eff Effect.Regeneration verbosity source target power =
  eff Effect.Heal verbosity source target power
eff Effect.Searching _ _source _target _power =
  returnNoFrame (True, "It gets lost and you search in vain.")
eff Effect.Ascend _ source target power = do
  tm <- gets (getActor target)
  s  <- get
  Kind.COps{coactor} <- getCOps
  if not $ isAHero s target
    then squashActor source target
    else effLvlGoUp (power + 1)
  -- TODO: The following message too late if a monster squashed:
  returnNoFrame (True, actorVerbExtra coactor tm "find" "a shortcut upstrairs")
eff Effect.Descend _ source target power = do
  tm <- gets (getActor target)
  s  <- get
  Kind.COps{coactor} <- getCOps
  if not $ isAHero s target
    then squashActor source target
    else effLvlGoUp (- (power + 1))
  -- TODO: The following message too late if a monster squashed:
  returnNoFrame (True,actorVerbExtra coactor tm "find" "a shortcut downstairs")

nullEffect :: ActionFrame (Bool, String)
nullEffect = returnNoFrame (False, "Nothing happens.")

-- TODO: refactor with actorAttackActor.
squashActor :: ActorId -> ActorId -> Action ()
squashActor source target = do
  Kind.COps{coactor, coitem=Kind.Ops{okind, ouniqGroup}} <- getCOps
  sm <- gets (getActor source)
  tm <- gets (getActor target)
  let h2hKind = ouniqGroup "weight"
      power = maxDeep $ ipower $ okind h2hKind
      h2h = Item h2hKind power Nothing 1
      verb = iverbApply $ okind h2hKind
      msg = actorVerbActorExtra coactor sm verb tm " in a staircase accident"
  msgAdd msg
  ((), noFrames) <- itemEffectAction 0 source target h2h
  s <- get
  -- The monster has to killed, because we may step there next turn.
  assert (not (memActor target s) `blame` (source, target, "not killed")) $
    -- Since monster is squashed, no extra frames generated to focus on it.
    assert (null noFrames `blame` length noFrames) $
      return ()

effLvlGoUp :: Int -> Action ()
effLvlGoUp k = do
  pbody     <- gets getPlayerBody
  pl        <- gets splayer
  slid      <- gets slid
  st        <- get
  cops      <- getCOps
  lvl <- gets slevel
  case whereTo st k of
    Nothing -> do -- we are at the "end" of the dungeon
      b <- displayYesNo "Really escape the dungeon?"
      if b
        then fleeDungeon
        else abortWith "Game resumed."
    Just (nln, nloc) ->
      assert (nln /= slid `blame` (nln, "stairs looped")) $ do
        bitems <- gets getPlayerItem
        -- Remember the level (e.g., for a teleport via scroll on the floor).
        remember
        -- Remove the player from the old level.
        modify (deleteActor pl)
        hs <- gets levelHeroList
        -- Monsters hear that players not on the level. Cancel smell.
        -- Reduces memory load and savefile size.
        when (L.null hs) $
          modify (updateLevel (updateSmell (const IM.empty)))
        -- At this place the invariant that the player exists fails.
        -- Change to the new level (invariant not needed).
        modify (\ s -> s {slid = nln})
        -- Add the player to the new level.
        modify (insertActor pl pbody)
        modify (updateAnyActorItem pl (const bitems))
        -- At this place the invariant is restored again.
        inhabitants <- gets (locToActor nloc)
        case inhabitants of
          Nothing -> return ()
          Just h | isAHero st h ->
            -- Bail out if a party member blocks the staircase.
            abortWith "somebody blocks the staircase"
          Just m ->
            -- Somewhat of a workaround: squash monster blocking the staircase.
            -- This is not a duplication with the other calls to squashActor,
            -- because here an inactive actor is squashed.
            squashActor pl m
        -- Verify the monster on the staircase died.
        inhabitants2 <- gets (locToActor nloc)
        when (isJust inhabitants2) $ assert `failure` inhabitants2
        -- Land the player at the other end of the stairs.
        updatePlayerBody (\ p -> p { bloc = nloc })
        -- Change the level of the player recorded in cursor.
        modify (updateCursor (\ c -> c { creturnLn = nln }))
        -- The invariant "at most one actor on a tile" restored.
        -- Create a backup of the savegame.
        state <- get
        diary <- getDiary
        saveGameBkp state diary
        -- TODO: lags behind perception
        msgAdd $ lookAt cops False True state lvl nloc ""

-- | The player leaves the dungeon.
fleeDungeon :: Action ()
fleeDungeon = do
  Kind.COps{coitem} <- getCOps
  state <- get
  diary <- getDiary
  saveGameBkp state diary -- save the diary
  let (items, total) = calculateTotal coitem state
  if total == 0
    then do
      go <- displayMoreConfirm ColorFull "Coward!"
      when go $
        displayMoreCancel "Next time try to grab some loot before escape!"
      end
    else do
      let winMsg = "Congratulations, you won! Your loot, worth " ++
                   show total ++ " gold, is:"  -- TODO: use the name of the '$' item instead
      io <- itemOverlay True items
      tryIgnore $ do
        displayOverConfirm winMsg io
        handleScores True H.Victor total
        displayMoreCancel "Can it be done better, though?"
      end

-- | The source actor affects the target actor, with a given item.
-- If the event is seen, the item may get identified.
itemEffectAction :: Int -> ActorId -> ActorId -> Item -> ActionFrame ()
itemEffectAction verbosity source target item = do
  Kind.COps{coitem=Kind.Ops{okind}} <- getCOps
  sm <- gets (getActor source)
  let effect = ieffect $ okind $ jkind item
  -- The msg describes the target part of the action.
  ((b1, b2), frames) <-
    effectToAction effect verbosity source target (jpower item)
  -- Party sees or affected, and the effect interesting,
  -- so the item gets identified.
  when (b1 && b2) $ discover item
  -- Destroys attacking actor and its items: a hack for projectiles.
  when (bhp sm <= 0) $
    modify (deleteActor source)
  return ((), frames)

-- | Make the item known to the player.
discover :: Item -> Action ()
discover i = do
  Kind.COps{coitem=coitem@Kind.Ops{okind}} <- getCOps
  state <- get
  let ik = jkind i
      obj = unwords $ tail $ words $ objectItem coitem state i
      msg = "The " ++ obj ++ " turns out to be "
      kind = okind ik
      alreadyIdentified = L.length (iflavour kind) == 1
                          || ik `S.member` sdisco state
  unless alreadyIdentified $ do
    modify (updateDiscoveries (S.insert ik))
    state2 <- get
    msgAdd $ msg ++ objectItem coitem state2 i ++ "."

-- | Make the actor controlled by the player.
-- Focus on the actor if level changes. False, if nothing to do.
selectPlayer :: ActorId -> Action Bool
selectPlayer actor = do
  Kind.COps{coactor} <- getCOps
  pl    <- gets splayer
  cops  <- getCOps
  lvl   <- gets slevel
  if actor == pl
    then return False -- already selected
    else do
      state <- get
      let (nln, pbody, _) = findActorAnyLevel actor state
      -- Make the new actor the player-controlled actor.
      modify (\ s -> s {splayer = actor})
      -- Record the original level of the new player.
      modify (updateCursor (\ c -> c {creturnLn = nln}))
      -- Don't continue an old run, if any.
      stopRunning
      -- Switch to the level.
      modify (\ s -> s {slid = nln})
      -- Announce.
      msgAdd $ capActor coactor pbody ++ " selected."
      msgAdd $ lookAt cops False True state lvl (bloc pbody) ""
      return True

focusIfOurs :: ActorId -> ActionFrame Bool
focusIfOurs target = do
  s  <- get
  pl <- gets splayer
  if isAHero s target || target == pl
    then do
      -- Focus on the hero being wounded/displaced/etc.
      b <- selectPlayer target
      -- Display status line for the new hero.
      if b
        then do
          -- Display status line and FOV for the new hero.
          fr <- drawPrompt ColorFull ""
          return (True, [fr])
        else returnNoFrame False
    else returnNoFrame False

summonHeroes :: Int -> Point -> ActionFrame ()
summonHeroes n loc =
  assert (n > 0) $ do
  cops <- getCOps
  newHeroId <- gets scounter
  modify (\ state -> iterate (addHero cops loc) state !! n)
  (b, frames) <- focusIfOurs newHeroId
  assert (b `blame` (newHeroId, "player summons himself")) $
    return ((), frames)

summonMonsters :: Int -> Point -> Action ()
summonMonsters n loc = do
  Kind.COps{cotile, coactor=Kind.Ops{opick, okind}} <- getCOps
  mk <- rndToAction $ opick "summon" (const True)
  hp <- rndToAction $ rollDice $ ahp $ okind mk
  modify (\ state ->
           iterate (addMonster cotile mk hp loc) state !! n)

-- | Update player memory.
remember :: Action ()
remember = do
  per <- getPerception
  let vis = IS.toList (totalVisible per)
  rememberList vis

rememberList :: [Point] -> Action ()
rememberList vis = do
  lvl <- gets slevel
  let rememberTile = [(loc, lvl `at` loc) | loc <- vis]
  modify (updateLevel (updateLRMap (Kind.// rememberTile)))
  let alt Nothing      = Nothing
      alt (Just ([], _)) = Nothing
      alt (Just (t, _))  = Just (t, t)
      rememberItem = IM.alter alt
  modify (updateLevel (updateIMap (\ m -> L.foldr rememberItem m vis)))

-- | Remove dead heroes (or dead dominated monsters). Check if game is over.
-- For now we only check the selected hero and at current level,
-- but if poison, etc. is implemented, we'd need to check all heroes
-- on any level.
checkPartyDeath :: Action ()
checkPartyDeath = do
  Kind.COps{coactor} <- getCOps
  ahs    <- gets allHeroesAnyLevel
  pl     <- gets splayer
  pbody  <- gets getPlayerBody
  config <- gets sconfig
  when (bhp pbody <= 0) $ do
    msgAdd $ actorVerb coactor pbody "die"
    go <- displayMoreConfirm ColorBW ""
    recordHistory  -- Prevent the msgs from being repeated.
    let firstDeathEnds = Config.get config "heroes" "firstDeathEnds"
    if firstDeathEnds
      then gameOver go
      else case L.filter (/= pl) ahs of
             [] -> gameOver go
             actor : _ -> do
               msgAdd "The survivors carry on."
               -- One last look at the beautiful world.
               remember
               -- Remove the dead player.
               modify deletePlayer
               -- At this place the invariant that the player exists fails.
               -- Focus on the new hero (invariant not needed),
               -- though don't draw a frame for him, in case the focus
               -- changes again during the same turn. He's just a random
               -- next guy in the line.
               selectPlayer actor
                 >>= assert `trueM` (pl, actor, "player resurrects")
               -- At this place the invariant is restored again.

-- | End game, showing the ending screens, if requested.
gameOver :: Bool -> Action a
gameOver showEndingScreens = do
  when showEndingScreens $ do
    Kind.COps{coitem} <- getCOps
    state <- get
    slid  <- gets slid
    let (_, total) = calculateTotal coitem state
        status = H.Killed slid
    handleScores True status total
    displayMoreCancel "Let's hope another party can save the day!"
  end

-- | Handle current score and display it with the high scores.
-- False if display of the scores was void or interrupted by the user.
--
-- Warning: scores are shown during the game,
-- so we should be careful not to leak secret information through them
-- (e.g., the nature of the items through the total worth of inventory).
handleScores :: Bool -> H.Status -> Int -> Action ()
handleScores write status total =
  when (total /= 0) $ do
    config  <- gets sconfig
    time    <- gets stime
    curDate <- currentDate
    let points = case status of
                   H.Killed _ -> (total + 1) `div` 2
                   _ -> total
    let score = H.ScoreRecord points (-time) curDate status
    (placeMsg, slideshow) <- registerHS config write score
    displayOverConfirm placeMsg slideshow

-- | Create a list of item names, split into many overlays.
itemOverlay ::Bool -> [Item] -> Action [Overlay]
itemOverlay sorted is = do
  Kind.COps{coitem} <- getCOps
  state <- get
  lysize <- gets (lysize . slevel)
  let inv = L.map (\ i -> letterLabel (jletter i)
                          ++ objectItem coitem state i ++ " ")
              ((if sorted
                then L.sortBy (cmpLetterMaybe `on` jletter)
                else id) is)
  return $ splitOverlay lysize inv

stopRunning :: Action ()
stopRunning = updatePlayerBody (\ p -> p { bdir = Nothing })

-- TODO: depending on tgt, show extra info about tile or monster or both
-- | Perform look around in the current location of the cursor.
doLook :: ActionFrame ()
doLook = do
  cops@Kind.COps{coactor} <- getCOps
  loc    <- gets (clocation . scursor)
  state  <- get
  lvl    <- gets slevel
  hms    <- gets (lactor . slevel)
  per    <- getPerception
  target <- gets (btarget . getPlayerBody)
  pl     <- gets splayer
  targeting <- gets (ctargeting . scursor)
  assert (targeting /= TgtOff) $ do
    let canSee = IS.member loc (totalVisible per)
        monsterMsg =
          if canSee
          then case L.find (\ m -> bloc m == loc) (IM.elems hms) of
                 Just m  -> actorVerbExtra coactor m "be" "here" ++ " "
                 Nothing -> ""
          else ""
        vis | not $ loc `IS.member` totalVisible per =
                " (not visible)"  -- by party
            | actorReachesLoc pl loc per (Just pl) = ""
            | otherwise = " (not reachable)"  -- by hero
        mode = case target of
                 TEnemy _ _ -> "[targeting monster" ++ vis ++ "] "
                 TLoc _     -> "[targeting location" ++ vis ++ "] "
                 TPath _    -> "[targeting path" ++ vis ++ "] "
                 TCursor    -> "[targeting current" ++ vis ++ "] "
        -- general info about current loc
        lookMsg = mode ++ lookAt cops True canSee state lvl loc monsterMsg
        -- check if there's something lying around at current loc
        is = lvl `rememberAtI` loc
    io <- itemOverlay False is
    if length is > 2
      then tryIgnoreFrame $ displayOverlays lookMsg io
      else do
        fr <- drawPrompt ColorFull lookMsg
        return ((), [fr])

gameVersion :: Action ()
gameVersion = do
  Kind.COps{corule} <- getCOps
  let pathsVersion = rpathsVersion $ stdRuleset corule
      msg = "Version " ++ showVersion pathsVersion
            ++ " (frontend: " ++ frontendName
            ++ ", engine: LambdaHack " ++ showVersion Self.version ++ ")"
  abortWith msg
