module Test.Main where

import Prelude
import Control.Monad.Aff (Aff, Canceler(..), ASYNC, nonCanceler, runAff, launchAff, makeAff, try, bracket, delay, forkAff, joinThread, killThread)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Console (CONSOLE)
import Control.Monad.Eff.Console as Console
import Control.Monad.Eff.Exception (Error, EXCEPTION, throwException, error, message)
import Control.Monad.Eff.Ref (REF, Ref)
import Control.Monad.Eff.Ref as Ref
import Control.Monad.Error.Class (throwError)
import Data.Bifunctor (lmap)
import Data.Either (Either(..), isLeft)
import Data.Foldable (sum)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Time.Duration (Milliseconds(..))
import Test.Assert (assert', ASSERT)

type TestEffects eff = (assert ∷ ASSERT, console ∷ CONSOLE, ref ∷ REF, exception ∷ EXCEPTION | eff)
type TestEff eff = Eff (TestEffects (async ∷ ASYNC | eff))
type TestAff eff = Aff (TestEffects eff)

newRef ∷ ∀ m eff a. MonadEff (ref ∷ REF | eff) m ⇒ a → m (Ref a)
newRef = liftEff <<< Ref.newRef

readRef ∷ ∀ m eff a. MonadEff (ref ∷ REF | eff) m ⇒ Ref a → m a
readRef = liftEff <<< Ref.readRef

writeRef ∷ ∀ m eff a. MonadEff (ref ∷ REF | eff) m ⇒ Ref a → a → m Unit
writeRef r = liftEff <<< Ref.writeRef r

modifyRef ∷ ∀ m eff a. MonadEff (ref ∷ REF | eff) m ⇒ Ref a → (a → a) → m Unit
modifyRef r = liftEff <<< Ref.modifyRef r

assertEff ∷ ∀ eff. String → Either Error Boolean → Eff (TestEffects eff) Unit
assertEff s = case _ of
  Left err → do
    Console.log ("[Error] " <> s)
    throwException err
  Right r → do
    assert' s r
    Console.log ("[OK] " <> s)

runAssert ∷ ∀ eff. String → TestAff eff Boolean → TestEff eff Unit
runAssert s = runAff (assertEff s)

runAssertEq ∷ ∀ eff a. Eq a ⇒ String → a → TestAff eff a → TestEff eff Unit
runAssertEq s a = runAff (assertEff s <<< map (eq a))

assertEq ∷ ∀ eff a. Eq a ⇒ String → a → TestAff eff a → TestAff eff Unit
assertEq s a aff = liftEff <<< assertEff s <<< map (eq a) =<< try aff

assert ∷ ∀ eff. String → TestAff eff Boolean → TestAff eff Unit
assert s aff = liftEff <<< assertEff s =<< try aff

test_pure ∷ ∀ eff. TestEff eff Unit
test_pure = runAssertEq "pure" 42 (pure 42)

test_bind ∷ ∀ eff. TestEff eff Unit
test_bind = runAssertEq "bind" 44 do
  n1 ← pure 42
  n2 ← pure (n1 + 1)
  n3 ← pure (n2 + 1)
  pure n3

test_try ∷ ∀ eff. TestEff eff Unit
test_try = runAssert "try" do
  n ← try (pure 42)
  case n of
    Right 42 → pure true
    _ → pure false

test_throw ∷ ∀ eff. TestEff eff Unit
test_throw = runAssert "try/throw" do
  n ← try (throwError (error "Nope."))
  pure (isLeft n)

test_liftEff ∷ ∀ eff. TestEff eff Unit
test_liftEff = runAssertEq "liftEff" 42 do
  ref ← newRef 0
  liftEff do
    writeRef ref 42
    readRef ref

test_delay ∷ ∀ eff. TestAff eff Unit
test_delay = assert "delay" do
  delay (Milliseconds 1000.0)
  pure true

test_fork ∷ ∀ eff. TestAff eff Unit
test_fork = assert "fork" do
  ref ← newRef 0
  thread ← forkAff do
    delay (Milliseconds 10.0)
    modifyRef ref (_ + 1)
  writeRef ref 42
  delay (Milliseconds 20.0)
  modifyRef ref (_ - 3)
  eq 40 <$> readRef ref

test_join ∷ ∀ eff. TestAff eff Unit
test_join = assert "join" do
  ref ← newRef 1
  thread ← forkAff do
    delay (Milliseconds 10.0)
    modifyRef ref (_ - 2)
    readRef ref
  writeRef ref 42
  eq 40 <$> joinThread thread

test_join_throw ∷ ∀ eff. TestAff eff Unit
test_join_throw = assert "join/throw" do
  thread ← forkAff do
    delay (Milliseconds 10.0)
    throwError (error "Nope.")
  isLeft <$> try (joinThread thread)

test_join_throw_sync ∷ ∀ eff. TestAff eff Unit
test_join_throw_sync = assert "join/throw/sync" do
  thread ← forkAff (throwError (error "Nope."))
  isLeft <$> try (joinThread thread)

test_multi_join ∷ ∀ eff. TestAff eff Unit
test_multi_join = assert "join/multi" do
  ref ← newRef 1
  thread1 ← forkAff do
    delay (Milliseconds 10.0)
    modifyRef ref (_ + 1)
    pure 10
  thread2 ← forkAff do
    delay (Milliseconds 20.0)
    modifyRef ref (_ + 1)
    pure 20
  n1 ← sum <$> traverse joinThread
    [ thread1
    , thread1
    , thread1
    , thread2
    ]
  n2 ← readRef ref
  pure (n1 == 50 && n2 == 3)

test_makeAff ∷ ∀ eff. TestAff eff Unit
test_makeAff = assert "makeAff" do
  ref1 ← newRef Nothing
  ref2 ← newRef 0
  thread ← forkAff do
    n ← makeAff \cb → do
      writeRef ref1 (Just cb)
      pure nonCanceler
    writeRef ref2 n
  cb ← readRef ref1
  case cb of
    Just k → do
      liftEff $ k (Right 42)
      eq 42 <$> readRef ref2
    Nothing → pure false

test_bracket ∷ ∀ eff. TestAff eff Unit
test_bracket = assert "bracket" do
  ref ← newRef []
  let
    action s = do
      delay (Milliseconds 10.0)
      modifyRef ref (_ <> [ s ])
      pure s
  thread ← forkAff do
    delay (Milliseconds 40.0)
    readRef ref
  _ ← bracket
    (action "foo")
    (\s → void $ action (s <> "/release"))
    (\s → action (s <> "/run"))
  joinThread thread <#> eq
    [ "foo"
    , "foo/run"
    , "foo/release"
    ]

test_bracket_nested ∷ ∀ eff. TestAff eff Unit
test_bracket_nested = assert "bracket/nested" do
  ref ← newRef []
  let
    action s = do
      delay (Milliseconds 10.0)
      modifyRef ref (_ <> [ s ])
      pure s
    bracketAction s =
      bracket
        (action (s <> "/bar"))
        (\s' → void $ action (s' <> "/release"))
        (\s' → action (s' <> "/run"))
  _ ← bracket
    (bracketAction "foo")
    (\s → void $ bracketAction (s <> "/release"))
    (\s → bracketAction (s <> "/run"))
  readRef ref <#> eq
    [ "foo/bar"
    , "foo/bar/run"
    , "foo/bar/release"
    , "foo/bar/run/run/bar"
    , "foo/bar/run/run/bar/run"
    , "foo/bar/run/run/bar/release"
    , "foo/bar/run/release/bar"
    , "foo/bar/run/release/bar/run"
    , "foo/bar/run/release/bar/release"
    ]

test_kill ∷ ∀ eff. TestAff eff Unit
test_kill = assert "kill" do
  thread ← forkAff $ makeAff \_ → pure nonCanceler
  killThread (error "Nope") thread
  isLeft <$> try (joinThread thread)

test_kill_canceler ∷ ∀ eff. TestAff eff Unit
test_kill_canceler = assert "kill/canceler" do
  ref ← newRef 0
  thread ← forkAff do
    n ← makeAff \_ → pure (Canceler \_ → liftEff (writeRef ref 42))
    writeRef ref 2
  killThread (error "Nope") thread
  res ← try (joinThread thread)
  n ← readRef ref
  pure (n == 42 && (lmap message res) == Left "Nope")

test_kill_bracket ∷ ∀ eff. TestAff eff Unit
test_kill_bracket = assert "kill/bracket" do
  ref ← newRef ""
  let
    action n = do
      delay (Milliseconds 10.0)
      modifyRef ref (_ <> n)
  thread ←
    forkAff $ bracket
      (action "a")
      (\_ → action "b")
      (\_ → action "c")
  killThread (error "Nope") thread
  _ ← try (joinThread thread)
  eq "ab" <$> readRef ref

test_kill_bracket_nested ∷ ∀ eff. TestAff eff Unit
test_kill_bracket_nested = assert "kill/bracket/nested" do
  ref ← newRef []
  let
    action s = do
      delay (Milliseconds 10.0)
      modifyRef ref (_ <> [ s ])
      pure s
    bracketAction s =
      bracket
        (action (s <> "/bar"))
        (\s' → void $ action (s' <> "/release"))
        (\s' → action (s' <> "/run"))
  thread ←
    forkAff $ bracket
      (bracketAction "foo")
      (\s → void $ bracketAction (s <> "/release"))
      (\s → bracketAction (s <> "/run"))
  killThread (error "Nope") thread
  _ ← try (joinThread thread)
  readRef ref <#> eq
    [ "foo/bar"
    , "foo/bar/run"
    , "foo/bar/release"
    , "foo/bar/run/release/bar"
    , "foo/bar/run/release/bar/run"
    , "foo/bar/run/release/bar/release"
    ]

main ∷ TestEff () Unit
main = do
  test_pure
  test_bind
  test_try
  test_throw
  test_liftEff

  void $ launchAff do
    test_delay
    test_fork
    test_join
    test_join_throw
    test_join_throw_sync
    test_multi_join
    test_makeAff
    test_bracket
    test_bracket_nested
    test_kill
    test_kill_canceler
    test_kill_bracket
    test_kill_bracket_nested
