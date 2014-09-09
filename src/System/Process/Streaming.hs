
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- system processes.
--
-- Error conditions that are not directly related to IO are made explicit
-- in the types.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and folds from
-- "Pipes.Prelude" (also folds from @pipes-bytestring@ and @pipes-text@)
-- can be used to consume the output streams of the external processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module System.Process.Streaming ( 
        -- * Execution
          execute
        , executeFallibly
        -- * Piping Policies
        , PipingPolicy
        , nopiping
        , pipeo
        , pipee
        , pipeoe
        , pipeoec
        , pipei
        , pipeio
        , pipeie
        , pipeioe
        , pipeioec

        -- * Pumping bytes into stdin
        , Pump (..)
        , fromProducer
        , fromSafeProducer
        , fromFallibleProducer
        -- * Siphoning bytes out of stdout/stderr
        , Siphon
        , siphon
        , runSiphon
        , fromConsumer
        , fromSafeConsumer
        , fromFallibleConsumer
        , fromFold
        , fromParser
        , unwanted
        , DecodingFunction
        , encoded
        -- * Line handling
        , LinePolicy
        , linePolicy
        -- * Pipelines
        , executePipeline
        , executePipelineFallibly
        -- , fromPipeline 
--        , simplePipeline 
--        , verySimplePipeline 
--        , BranchingPipeline (..)
--        , PipelineForest (..)
        , CreatePipeline (..)
        , simplePipeline
        , Stage (..)
        , SubsequentStage ()
        , subsequent
        -- * Re-exports
        -- $reexports
        , module System.Process
    ) where

import Data.Maybe
import Data.Bifunctor
import Data.Functor.Identity
import Data.Either
import Data.Monoid
import Data.Foldable
import Data.Traversable
import Data.Typeable
import Data.Tree
import Data.Text 
import Data.Text.Encoding 
import Data.Void
import Data.List.NonEmpty
import qualified Data.List.NonEmpty as N
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Writer.Strict
import qualified Control.Monad.Catch as C
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Pipes
import qualified Pipes as P
import qualified Pipes.Prelude as P
import Pipes.Lift
import Pipes.ByteString
import Pipes.Parse
import qualified Pipes.Text as T
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.IO.Error
import System.Process
import System.Process.Lens
import System.Exit

execute :: PipingPolicy Void a -> CreateProcess -> IO (ExitCode,a)
execute pp cprocess = either absurd id <$> executeFallibly pp cprocess

{-|
   Executes an external process. The standard streams are piped and consumed in
a way defined by the 'PipingPolicy' argument. 

   This fuction re-throws any 'IOException's it encounters.

   If the consumption of the standard streams fails with @e@, the whole
computation is immediately aborted and @e@ is returned. (An exception is not
thrown in this case.).  

   If an error @e@ or an exception happens, the external process is
terminated.
 -}
executeFallibly :: PipingPolicy e a -> CreateProcess -> IO (Either e (ExitCode,a))
executeFallibly pp record = case pp of
      PPNone a -> executeInternal record nohandles $  
          \() -> (return . Right $ a,return ())
      PPOutput action -> executeInternal (record{std_out = CreatePipe}) handleso $
          \h->(action (fromHandle h),hClose h) 
      PPError action ->  executeInternal (record{std_err = CreatePipe}) handlese $
          \h->(action (fromHandle h),hClose h)
      PPOutputError action -> executeInternal (record{std_out = CreatePipe, std_err = CreatePipe}) handlesoe $
          \(hout,herr)->(action (fromHandle hout,fromHandle herr),hClose hout `finally` hClose herr)
      PPInput action -> executeInternal (record{std_in = CreatePipe}) handlesi $
          \h -> (action (toHandle h, hClose h), return ())
      PPInputOutput action -> executeInternal (record{std_in = CreatePipe,std_out = CreatePipe}) handlesio $
          \(hin,hout) -> (action (toHandle hin,hClose hin,fromHandle hout), hClose hout)
      PPInputError action -> executeInternal (record{std_in = CreatePipe,std_err = CreatePipe}) handlesie $
          \(hin,herr) -> (action (toHandle hin,hClose hin,fromHandle herr), hClose herr)
      PPInputOutputError action -> executeInternal (record{std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}) handlesioe $
          \(hin,hout,herr) -> (action (toHandle hin,hClose hin,fromHandle hout,fromHandle herr), hClose hout `finally` hClose herr)

executeInternal :: CreateProcess -> (forall m. Applicative m => (t -> m t) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)) -> (t ->(IO (Either e a),IO ())) -> IO (Either e (ExitCode,a))
executeInternal record somePrism allocator = mask $ \restore -> do
    (min,mout,merr,phandle) <- createProcess record
    case getFirst . getConst . somePrism (Const . First . Just) $ (min,mout,merr) of
        Nothing -> 
            throwIO (userError "stdin/stdout/stderr handle unwantedly null")
            `finally`
            terminateCarefully phandle 
        Just t -> 
            let (action,cleanup) = allocator t in
            -- Handles must be closed *after* terminating the process, because a close
            -- operation may block if the external process has unflushed bytes in the stream.
            (restore (terminateOnError phandle action) `onException` terminateCarefully phandle) `finally` cleanup 

exitCode :: (ExitCode,a) -> Either Int a
exitCode (ec,a) = case ec of
    ExitSuccess -> Right a 
    ExitFailure i -> Left i

terminateCarefully :: ProcessHandle -> IO ()
terminateCarefully pHandle = do
    mExitCode <- getProcessExitCode pHandle   
    case mExitCode of 
        Nothing -> terminateProcess pHandle  
        Just _ -> return ()

terminateOnError :: ProcessHandle 
                 -> IO (Either e a)
                 -> IO (Either e (ExitCode,a))
terminateOnError pHandle action = do
    result <- action
    case result of
        Left e -> do    
            terminateCarefully pHandle
            return $ Left e
        Right r -> do 
            exitCode <- waitForProcess pHandle 
            return $ Right (exitCode,r)  

{-|
    A 'PipingPolicy' determines what standard streams will be piped and what to
do with them.

    The user doesn't need to manually set the 'std_in', 'std_out' and 'std_err'
fields of the 'CreateProcess' record to 'CreatePipe', this is done
automatically. 

    A 'PipingPolicy' is parametrized by the type @e@ of errors that can abort
the processing of the streams.
 -}
-- Knows that there is a stdin, stdout and a stderr,
-- but doesn't know anything about file handlers or CreateProcess.
data PipingPolicy e a = 
      PPNone a
    | PPOutput (Producer ByteString IO () -> IO (Either e a))
    | PPError  (Producer ByteString IO () -> IO (Either e a))
    | PPOutputError ((Producer ByteString IO (),Producer ByteString IO ()) -> IO (Either e a))
    | PPInput ((Consumer ByteString IO (), IO ()) -> IO (Either e a))
    | PPInputOutput ((Consumer ByteString IO (), IO (),Producer ByteString IO ()) -> IO (Either e a))
    | PPInputError  ((Consumer ByteString IO (), IO (), Producer ByteString IO ()) -> IO (Either e a))
    | PPInputOutputError  ((Consumer ByteString IO (),IO (),Producer ByteString IO (),Producer ByteString IO ()) -> IO (Either e a))
    deriving (Functor)

instance Bifunctor PipingPolicy where
  bimap f g pp = case pp of
        PPNone a -> PPNone $ g a 
        PPOutput action -> PPOutput $ fmap (fmap (bimap f g)) action
        PPError action -> PPError $ fmap (fmap (bimap f g)) action
        PPOutputError action -> PPOutputError $ fmap (fmap (bimap f g)) action
        PPInput action -> PPInput $ fmap (fmap (bimap f g)) action
        PPInputOutput action -> PPInputOutput $ fmap (fmap (bimap f g)) action
        PPInputError action -> PPInputError $ fmap (fmap (bimap f g)) action
        PPInputOutputError action -> PPInputOutputError $ fmap (fmap (bimap f g)) action

{-|
    Do not pipe any standard stream. 
-}
nopiping :: PipingPolicy e ()
nopiping = PPNone ()

{-|
    Pipe @stdout@.
-}
pipeo :: (Show e,Typeable e) => Siphon ByteString e a -> PipingPolicy e a
pipeo (Siphon siphonout) = PPOutput $ siphonout

{-|
    Pipe @stderr@.
-}
pipee :: (Show e,Typeable e) => Siphon ByteString e a -> PipingPolicy e a
pipee (Siphon siphonout) = PPError $ siphonout

{-|
    Pipe @stdout@ and @stderr@.
-}
pipeoe :: (Show e,Typeable e) => Siphon ByteString e a -> Siphon ByteString e b -> PipingPolicy e (a,b)
pipeoe (Siphon siphonout) (Siphon siphonerr) = 
    PPOutputError $ uncurry $ separated siphonout siphonerr  

{-|
    Pipe @stdout@ and @stderr@ and consume them combined as 'Text'.  
-}
pipeoec :: (Show e,Typeable e) => LinePolicy e -> LinePolicy e -> Siphon Text e a -> PipingPolicy e a
pipeoec policy1 policy2 (Siphon siphon) = 
    PPOutputError $ uncurry $ combined policy1 policy2 siphon  

{-|
    Pipe @stdin@.
-}
pipei :: (Show e, Typeable e) => Pump ByteString e i -> PipingPolicy e i
pipei (Pump feeder) = PPInput $ \(consumer,cleanup) -> feeder consumer `finally` cleanup

{-|
    Pipe @stdin@ and @stdout@.
-}
pipeio :: (Show e, Typeable e)
        => Pump ByteString e i -> Siphon ByteString e a -> PipingPolicy e (i,a)
pipeio (Pump feeder) (Siphon siphonout) = PPInputOutput $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonout producer))

{-|
    Pipe @stdin@ and @stderr@.
-}
pipeie :: (Show e, Typeable e)
        => Pump ByteString e i -> Siphon ByteString e a -> PipingPolicy e (i,a)
pipeie (Pump feeder) (Siphon siphonerr) = PPInputError $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonerr producer))

{-|
    Pipe @stdin@, @stdout@ and @stderr@.
-}
pipeioe :: (Show e, Typeable e)
        => Pump ByteString e i -> Siphon ByteString e a -> Siphon ByteString e b -> PipingPolicy e (i,a,b)
pipeioe (Pump feeder) (Siphon siphonout) (Siphon siphonerr) = fmap flattenTuple $ PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (separated siphonout siphonerr outprod errprod))
    where
        flattenTuple (i, (a, b)) = (i,a,b)

{-|
    Pipe @stdin@, @stdout@ and @stderr@, consuming the last two combined as 'Text'.
-}
pipeioec :: (Show e, Typeable e)
        => Pump ByteString e i -> LinePolicy e -> LinePolicy e -> Siphon Text e a -> PipingPolicy e (i,a)
pipeioec (Pump feeder) policy1 policy2 (Siphon siphon) = PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (combined policy1 policy2 siphon outprod errprod))

{-|
    'separate' should be used when we want to consume @stdout@ and @stderr@
concurrently and independently. It constructs a function that can be plugged
into functions like 'pipeoe'. 

    If the consuming functions return with @a@ and @b@, the corresponding
streams keep being drained until the end. The combined value is not returned
until both @stdout@ and @stderr@ are closed by the external process.

   However, if any of the consuming functions fails with @e@, the whole
computation fails immediately with @e@.
  -}
separated :: (Show e, Typeable e)
          => (Producer ByteString IO () -> IO (Either e a))
          -> (Producer ByteString IO () -> IO (Either e b))
          ->  Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separated outfunc errfunc outprod errprod = 
    conceit (buffer_ outfunc outprod) (buffer_ errfunc errprod)

{-|
   Defines how to decode a stream of bytes into text, including what to do
   in presence of leftovers. Also defines how to manipulate each individual
   line of text.  
 -}
data LinePolicy e = LinePolicy ((FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> Producer ByteString IO () -> IO (Either e ()))

instance Functor LinePolicy where
  fmap f (LinePolicy func) = LinePolicy $ fmap (fmap (fmap (bimap f id))) func

{-|
    Constructs a 'LinePolicy'.

    The second argument is a 'Siphon' value that specifies how to handle
decoding failures. Passing @pure ()@ will ignore any leftovers. Passing
@unwanted ()@ will abort the computation if leftovers remain.

    The third argument is a function that modifies each individual line.
    The line is represented as a 'Producer' to avoid having to keep it
    wholly in memory. If you want the lines unmodified, just pass @id@.
    Line prefixes are easy to add using applicative notation:

  > (\x -> yield "prefix: " *> x)

 -}

linePolicy :: (Show e, Typeable e)
           => DecodingFunction ByteString Text 
           -> Siphon ByteString e ()
           -> (forall r. Producer T.Text IO r -> Producer T.Text IO r)
           ->  LinePolicy e 
linePolicy decoder lopo transform = LinePolicy $ \teardown producer -> do
    let freeLines = transFreeT transform 
                  . viewLines 
                  . decoder
                  $ producer
        viewLines = getConst . T.lines Const
    teardown freeLines >>= runSiphon lopo

{-|
    The bytes from @stdout@ and @stderr@ are decoded into 'Text', splitted into
lines (maybe applying some transformation to each line) and then combined and
consumed by the function passed as argument.

    For both @stdout@ and @stderr@, a 'LinePolicy' must be supplied.

    Like with 'separated', the streams are drained to completion if no errors
happen, but the computation is aborted immediately if any error @e@ is
returned. 

    'combined' returns a function that can be plugged into funtions like 'pipeioe'.

    /Beware!/ 'combined' avoids situations in which a line emitted
in @stderr@ cuts a long line emitted in @stdout@, see
<http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here> for a description of the problem.  To avoid this, the combined text
stream is locked while writing each individual line. But this means that if the
external program stops writing to a handle /while in the middle of a line/,
lines coming from the other handles won't get printed, either!
 -}
combined :: (Show e, Typeable e) 
         => LinePolicy e 
         -> LinePolicy e 
         -> (Producer T.Text IO () -> IO (Either e a))
         -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a)
combined (LinePolicy fun1) (LinePolicy fun2) combinedConsumer prod1 prod2 = 
    manyCombined [fmap (($prod1).buffer_) fun1, fmap (($prod2).buffer_) fun2] combinedConsumer 
    
manyCombined :: (Show e, Typeable e) 
             => [(FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> IO (Either e ())]
        	 -> (Producer T.Text IO () -> IO (Either e a))
        	 -> IO (Either e a) 
manyCombined actions consumer = do
    (outbox, inbox, seal) <- spawn' Single
    mVar <- newMVar outbox
    runConceit $ 
        Conceit (mapConceit ($ iterTLines mVar) actions `finally` atomically seal)
        *>
        Conceit (consumer (fromInput inbox) `finally` atomically seal)
    where 
    iterTLines mvar = iterT $ \textProducer -> do
        -- the P.drain bit was difficult to figure out!!!
        join $ withMVar mvar $ \output -> do
            runEffect $ (textProducer <* P.yield (singleton '\n')) >-> (toOutput output >> P.drain)

errorSiphonUTF8 :: MVar (Output ByteString) -> LinePolicy e -> Siphon ByteString e ()
errorSiphonUTF8 mvar (LinePolicy fun) = Siphon $ fun iterTLines 
  where     
    iterTLines = iterT $ \textProducer -> do
        -- the P.drain bit was difficult to figure out!!!
        join $ withMVar mvar $ \output -> do
            runEffect $     (textProducer <* P.yield (singleton '\n')) 
                        >->  P.map Data.Text.Encoding.encodeUtf8 
                        >-> (toOutput output >> P.drain)

fromConsumer :: (Show e, Typeable e) => Consumer b IO () -> Siphon b e ()
fromConsumer consumer = siphon $ \producer -> fmap pure $ runEffect $ producer >-> consumer 

fromSafeConsumer :: (Show e, Typeable e) => Consumer b (SafeT IO) () -> Siphon b e ()
fromSafeConsumer consumer = siphon $ safely $ \producer -> fmap pure $ runEffect $ producer >-> consumer 

fromFallibleConsumer :: (Show e, Typeable e) => Consumer b (ExceptT e IO) () -> Siphon b e ()
fromFallibleConsumer consumer = siphon $ \producer -> runExceptT $ runEffect (hoist lift producer >-> consumer) 

fromFold :: (Show e, Typeable e) => (Producer b IO () -> IO a) -> Siphon b e a 
fromFold aFold = siphon $ fmap (fmap pure) $ aFold 

fromParser :: (Show e, Typeable e) => Parser b IO (Either e a) -> Siphon b e a 
fromParser parser = siphon $ Pipes.Parse.evalStateT parser 

fromProducer :: Producer b IO () -> Pump b e ()
fromProducer producer = Pump $ \consumer -> fmap pure $ runEffect (producer >-> consumer) 

fromSafeProducer :: Producer b (SafeT IO) () -> Pump b e ()
fromSafeProducer producer = Pump $ safely $ \consumer -> fmap pure $ runEffect (producer >-> consumer) 

fromFallibleProducer :: Producer b (ExceptT e IO) () -> Pump b e ()
fromFallibleProducer producer = Pump $ \consumer -> runExceptT $ runEffect (producer >-> hoist lift consumer) 

{-| 
  Useful when we want to plug in a handler that does its work in the 'SafeT'
transformer.
 -}
safely :: (MFunctor t, C.MonadMask m, MonadIO m) 
       => (t (SafeT m) l -> (SafeT m) x) 
       ->  t m         l -> m         x 
safely activity = runSafeT . activity . hoist lift 

buffer :: (Show e, Typeable e)
       =>  Siphon bytes e (a -> b)
       ->  Siphon text e a
       ->  Producer text  IO (Producer bytes IO ()) -> IO (Either e b)
buffer policy activity producer = do
    (outbox,inbox,seal) <- spawn' Single
    r <- conceit 
              (do feeding <- async $ runEffect $ 
                        producer >-> (toOutput outbox >> P.drain)
                  Right <$> wait feeding `finally` atomically seal
              )
              (runSiphon activity (fromInput inbox) `finally` atomically seal)
    case r of 
        Left e -> return $ Left e
        Right (leftovers,a) -> runSiphon (fmap ($a) policy) leftovers

runSiphon :: (Show e, Typeable e)
          => Siphon b e a 
          -> (Producer b IO () -> IO (Either e a))
runSiphon (Siphon s) = s

{-| 
   Builds a 'Siphon' out of a computation that does something with
   a 'Producer' and may suddenly fail with an error of type @e@.
   
   Even if the original computation doesn't completely drain the 'Producer',
   the constructed 'Siphon' will.
-}
siphon :: (Show e, Typeable e)
       => (Producer b IO () -> IO (Either e a))
       -> Siphon b e a 
siphon = Siphon . buffer_

buffer_ :: (Show e, Typeable e) 
        => (Producer b IO () -> IO (Either e a))
        ->  Producer b IO () -> IO (Either e a)
buffer_ activity producer = do
    (outbox,inbox,seal) <- spawn' Single
    runConceit $
        Conceit (do feeding <- async $ runEffect $ 
                        producer >-> (toOutput outbox >> P.drain)
                    Right <$> wait feeding `finally` atomically seal
                )
        *>
        Conceit (activity (fromInput inbox) `finally` atomically seal)

{-|
    See the section /Non-lens decoding functions/ in the documentation for the
@pipes-text@ package.  
-}
type DecodingFunction bytes text = forall r. Producer bytes IO r -> Producer text IO (Producer bytes IO r)

{-|
    Constructs a 'Siphon' that works on undecoded values out of a 'Siphon' that
works on decoded values. 
   
    The two first arguments are a decoding function and a 'Siphon' that
determines how to handle leftovers. Pass @pure id@ to ignore leftovers. Pass
@unwanted id@ to abort the computation if leftovers remain.
 -}
encoded :: (Show e, Typeable e) 
        => DecodingFunction bytes text
        -> Siphon bytes e (a -> b)
        -> Siphon text  e a 
        -> Siphon bytes e b
encoded decoder policy activity = Siphon $ \producer -> buffer policy activity $ decoder producer 


data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

newtype Conceit e a = Conceit { runConceit :: IO (Either e a) }

instance Functor (Conceit e) where
  fmap f (Conceit x) = Conceit $ fmap (fmap f) x

instance Bifunctor Conceit where
  bimap f g (Conceit x) = Conceit $ liftM (bimap f g) x

instance (Show e, Typeable e) => Applicative (Conceit e) where
  pure = Conceit . pure . pure
  Conceit fs <*> Conceit as =
    Conceit . revealError $ 
        uncurry ($) <$> concurrently (elideError fs) (elideError as)

instance (Show e, Typeable e) => Alternative (Conceit e) where
  empty = Conceit $ forever (threadDelay maxBound)
  Conceit as <|> Conceit bs =
    Conceit $ either id id <$> race as bs

instance (Show e, Typeable e, Monoid a) => Monoid (Conceit e a) where
   mempty = Conceit . pure . pure $ mempty
   mappend c1 c2 = (<>) <$> c1 <*> c2

conceit :: (Show e, Typeable e) 
        => IO (Either e a)
        -> IO (Either e b)
        -> IO (Either e (a,b))
conceit c1 c2 = runConceit $ (,) <$> Conceit c1 <*> Conceit c2

{-| 
      Works similarly to 'Control.Concurrent.Async.mapConcurrently' from the
@async@ package, but if any of the computations fails with @e@, the others are
immediately cancelled and the whole computation fails with @e@. 
 -}
mapConceit :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConceit f = revealError .  mapConcurrently (elideError . f)

newtype Pump b e a = Pump { runPump :: Consumer b IO () -> IO (Either e a) }

instance Functor (Pump b e) where
  fmap f (Pump x) = Pump $ fmap (fmap (fmap f)) x

instance Bifunctor (Pump b) where
  bimap f g (Pump x) = Pump $ fmap (liftM  (bimap f g)) x

instance (Show e, Typeable e) => Applicative (Pump b e) where
  pure = Pump . pure . pure . pure
  Pump fs <*> Pump as = 
      Pump $ \consumer -> do
          (outbox1,inbox1,seal1) <- spawn' Single
          (outbox2,inbox2,seal2) <- spawn' Single
          runConceit $ 
              Conceit (runExceptT $ do
                           r1 <- ExceptT $ (fs $ toOutput outbox1) 
                                               `finally` atomically seal1
                           r2 <- ExceptT $ (as $ toOutput outbox2) 
                                               `finally` atomically seal2
                           return $ r1 r2 
                      )
              <* 
              Conceit (do
                         (runEffect $
                             (fromInput inbox1 >> fromInput inbox2) >-> consumer)
                            `finally` atomically seal1
                            `finally` atomically seal2
                         return $ pure ()
                      )

instance (Show e, Typeable e, Monoid a) => Monoid (Pump b e a) where
   mempty = Pump . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

{-| 
    A 'Siphon' represents a computation that either completely drains a
    producer, or fails early with an error of type @e@. 

    'pure' creates a 'Siphon' that drains a 'Producer' and returns the
    value passed as parameter. 

    '<*>' executes its arguments concurrently. The 'Producer' is forked so
    that each argument receives its own copy of the data.
 -}
newtype Siphon b e a = Siphon (Producer b IO () -> IO (Either e a))

instance Functor (Siphon b e) where
  fmap f (Siphon x) = Siphon $ fmap (fmap (fmap f)) x

instance Bifunctor (Siphon b) where
  bimap f g (Siphon x) = Siphon $ fmap (liftM  (bimap f g)) x

instance (Show e, Typeable e) => Applicative (Siphon b e) where
  pure = Siphon . pure . pure . pure
  Siphon fs <*> Siphon as = 
      Siphon $ \producer -> do
          (outbox1,inbox1,seal1) <- spawn' Single
          (outbox2,inbox2,seal2) <- spawn' Single
          runConceit $
              Conceit (do
                         -- mmm who cancels these asyncs ??
                         feeding <- async $ runEffect $ 
                             producer >-> P.tee (toOutput outbox1 >> P.drain) 
                                      >->       (toOutput outbox2 >> P.drain)   
                         -- is these async neccessary ??
                         sealing <- async $ wait feeding `finally` atomically seal1 
                                                         `finally` atomically seal2
                         return $ pure ()
                      )
              *>
              Conceit (fmap (uncurry ($)) <$> conceit ((fs $ fromInput inbox1) 
                                                      `finally` atomically seal1) 
                                                      ((as $ fromInput inbox2) 
                                                      `finally` atomically seal2) 
                      )

instance (Show e, Typeable e, Monoid a) => Monoid (Siphon b e a) where
   mempty = Siphon . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

{-|
  Constructs a 'Siphon' that aborts the computation if the underlying
'Producer' produces anything.
 -}
unwanted :: (Show b, Typeable b) => a -> Siphon b b a
unwanted a = siphon $ \producer -> do
    r <- next producer  
    return $ case r of 
        Left () -> Right a
        Right (b,_) -> Left b

executePipeline :: PipingPolicy Void a -> CreatePipeline Void -> IO a 
executePipeline pp pipeline = either absurd id <$> executePipelineFallibly pp pipeline


{-|
    Similar to 'executeFallibly', but instead of a single process it
    executes a (possibly branching) pipeline of external processes. 

    The 'PipingPolicy' argument views the pipeline as a synthetic process
    for which @stdin@ is the @stdin@ of the first stage, @stdout@ is the
    @stdout@ of the leftmost terminal stage among those closer to the root,
    and @stderr@ is a combination of the @stderr@ streams of all the
    stages.

    The combined @stderr@ stream always has UTF-8 encoding.

    This function has a limitation compared to the standard UNIX pipelines.
    If a downstream process terminates early without error, the upstream
    processes are not notified and keep going. There is no SIGPIPE-like
    functionality, in other words. 
 -}
executePipelineFallibly :: (Show e,Typeable e) => PipingPolicy e a -> CreatePipeline e -> IO (Either e a)
executePipelineFallibly policy pipeline = case policy of 
      PPNone a -> fmap (fmap (const a)) $
           executePipelineInternal 
                (\o _ -> mute $ pipeo o) 
                (\i o _ -> mute $ pipeio i o) 
                (\i _ -> mute $ pipei i) 
                (\i _ -> mute $ pipei i) 
                pipeline
      PPOutput action -> do
            (outbox, inbox, seal) <- spawn' Single
            runConceit $  
                (Conceit $ action $ fromInput inbox)
                <* 
                (Conceit $ executePipelineInternal 
                                (\o _ -> pipeo o)
                                (\i o _ -> mute $ pipeio i o) 
                                (\i _ -> mute $ pipeio i (fromConsumer . toOutput $ outbox)) 
                                (\i _ -> mute $ pipei i)
                                pipeline
                           `finally` atomically seal
                ) 
      PPError action -> do
            (eoutbox, einbox, eseal) <- spawn' Single
            errf <- errorSiphonUTF8 <$> newMVar eoutbox
            runConceit $  
                (Conceit $ action $ fromInput einbox)
                <*
                (Conceit $ executePipelineInternal 
                            (\o l -> mute $ pipeoe o (errf l)) 
                            (\i o l -> mute $ pipeioe i o (errf l)) 
                            (\i l -> mute $ pipeie i (errf l)) 
                            (\i l -> mute $ pipeie i (errf l))
                            pipeline
                            `finally` atomically eseal)
      PPOutputError action -> do
            (outbox, inbox, seal) <- spawn' Single
            (eoutbox, einbox, eseal) <- spawn' Single
            errf <- errorSiphonUTF8 <$> newMVar eoutbox
            runConceit $  
                (Conceit $ action $ (fromInput inbox,fromInput einbox))
                <* 
                (Conceit $ executePipelineInternal 
                                (\o l -> mute $ pipeoe o (errf l))
                                (\i o l -> mute $ pipeioe i o (errf l)) 
                                (\i l -> mute $ pipeioe i (fromConsumer . toOutput $ outbox) (errf l)) 
                                (\i l -> mute $ pipeie i (errf l))
                                pipeline
                           `finally` atomically seal `finally` atomically eseal
                )
      PPInput action -> do
            (outbox, inbox, seal) <- spawn' Single
            runConceit $  
                (Conceit $ action (toOutput outbox,atomically seal))
                <* 
                (Conceit $ executePipelineInternal 
                                (\o _ -> mute $ pipeio (fromProducer . fromInput $ inbox) o)
                                (\i o _ -> mute $ pipeio i o) 
                                (\i _ -> mute $ pipei i) 
                                (\i _ -> mute $ pipei i) 
                                pipeline
                           `finally` atomically seal
                )
      PPInputOutput action -> do
            (ioutbox, iinbox, iseal) <- spawn' Single
            (ooutbox, oinbox, oseal) <- spawn' Single
            runConceit $  
                (Conceit $ action (toOutput ioutbox,atomically iseal,fromInput oinbox))
                <* 
                (Conceit $ executePipelineInternal 
                                (\o _ -> mute $ pipeio (fromProducer . fromInput $ iinbox) o)
                                (\i o _ -> mute $ pipeio i o) 
                                (\i _ -> mute $ pipeio i (fromConsumer . toOutput $ ooutbox)) 
                                (\i _ -> mute $ pipei i) 
                                pipeline
                           `finally` atomically iseal `finally` atomically oseal
                )
      PPInputError action -> do
            (outbox, inbox, seal) <- spawn' Single
            (eoutbox, einbox, eseal) <- spawn' Single
            errf <- errorSiphonUTF8 <$> newMVar eoutbox
            runConceit $  
                (Conceit $ action (toOutput outbox,atomically seal,fromInput einbox))
                <* 
                (Conceit $ executePipelineInternal 
                                (\o l -> mute $ pipeioe (fromProducer . fromInput $ inbox) o (errf l))
                                (\i o l -> mute $ pipeioe i o (errf l)) 
                                (\i l -> mute $ pipeie i (errf l)) 
                                (\i l -> mute $ pipeie i (errf l)) 
                                pipeline
                           `finally` atomically seal `finally` atomically eseal
                )
      PPInputOutputError action -> do
            (ioutbox, iinbox, iseal) <- spawn' Single
            (ooutbox, oinbox, oseal) <- spawn' Single
            (eoutbox, einbox, eseal) <- spawn' Single
            errf <- errorSiphonUTF8 <$> newMVar eoutbox
            runConceit $  
                (Conceit $ action (toOutput ioutbox,atomically iseal,fromInput oinbox,fromInput einbox))
                <* 
                (Conceit $ executePipelineInternal 
                                (\o l -> mute $ pipeioe (fromProducer . fromInput $ iinbox) o (errf l))
                                (\i o l -> mute $ pipeioe i o (errf l)) 
                                (\i l -> mute $ pipeioe i (fromConsumer . toOutput $ ooutbox) (errf l)) 
                                (\i l -> mute $ pipeie i (errf l))  
                                pipeline
                           `finally` atomically iseal `finally` atomically oseal `finally` atomically eseal
                )
    where mute = fmap (const ())


-- data Pipeline e = Pipeline (Stage e) (NonEmpty (SubsequentStage e)) deriving (Functor)

{-|
   An individual stage in a process pipeline. 
   
   The 'LinePolicy' field defines how to handle @stderr@ when @stderr@ is
   piped. 
   
   Also required is a function that determines if the returned exit code
   represents an error or not. This is necessary because some programs use
   non-standard exit codes.
 -}
data Stage e = Stage 
           {
             processDefinition :: CreateProcess 
           , stderrLinePolicy :: LinePolicy e
           , exitCodePolicy :: Int -> Maybe e
           } deriving (Functor)


{-|
   Any stage beyond the first in a process pipeline. 
 -}
data SubsequentStage e = SubsequentStage (FalliblePipe ByteString ByteString IO e) (Stage e) deriving (Functor)

data FalliblePipe b b' m e = FalliblePipe (forall a.Pipe b b' (ExceptT e m) a)

instance (Monad m) => Functor (FalliblePipe b b' m) where
    fmap f (FalliblePipe bs) = FalliblePipe $ hoist (mapExceptT $ liftM (bimap f id)) bs

{-|
   Builds a 'SubsequentStage' from a 'Stage' by prepending a 'Pipe' that is
   applied to the stream of data that the 'Stage' receives.

   Pass 'cat' (the identity 'Pipe' from 'Pipes') as argument if no
   pre-processing is required.
 -}
subsequent :: (forall a.Pipe ByteString ByteString (ExceptT e IO) a) -> Stage e -> SubsequentStage e
subsequent fp s = SubsequentStage (FalliblePipe fp) s 

data CreatePipeline e =  CreatePipeline (Stage e) (NonEmpty (Tree (SubsequentStage e))) deriving (Functor)

--data PipelineForest e =
--        ParallelStages (NonEmpty (SubsequentStage e, PipelineForest e))
--      | TerminalStage (SubsequentStage e)
--      deriving (Functor)

-- fromPipeline :: Pipeline e -> BranchingPipeline e
-- fromPipeline (Pipeline root (liftA2 (,) N.init N.last -> (stages, finalStage))) = 
--     (BranchingPipeline root arborescent)
--         where arborescent = Data.Foldable.foldr (curry $ ParallelStages . pure) (TerminalStage finalStage) stages


{-|
    Build a linear pipeline out of an initial 'Stage', a list of
    intermediate 'SubsequentStage's, and a terminal 'SubsequentStage'.
-}
-- simplePipeline :: Stage e -> [SubsequentStage e] -> SubsequentStage e -> BranchingPipeline e 
-- simplePipeline initial middle terminal = BranchingPipeline initial $   
--    Prelude.foldr (\s1 s2 -> ParallelStages . pure $ (s1,s2)) (TerminalStage terminal) middle

{-|
    Build a linear pipeline out of an initial process, a list of
    intermediate processes, and one final process. 

    The @stderr@ streams of all the processes in the pipeline are assumed
    to have the encoding specified by the 'DecodingFunction' parameter.
-}
-- verySimplePipeline :: DecodingFunction ByteString Text -> CreateProcess -> [CreateProcess] -> CreateProcess -> BranchingPipeline String 
-- verySimplePipeline decoder initial middle end = 
--     simplePipeline (simpleStage initial) (Prelude.map simpleSubsequentStage middle) (simpleSubsequentStage end) 
--   where
--     simpleStage cp = Stage cp simpleLinePolicy simpleErrorPolicy
--     simpleSubsequentStage = SubsequentStage (FalliblePipe P.cat) . simpleStage
--     simpleLinePolicy = linePolicy decoder (pure ()) id
--     simpleErrorPolicy = Just . ("Exit failure: " ++) . show

simplePipeline :: DecodingFunction ByteString Text -> CreateProcess -> NonEmpty (Tree (CreateProcess)) -> CreatePipeline String 
simplePipeline decoder initial forest = CreatePipeline (simpleStage initial) (fmap (fmap simpleSubsequentStage) forest)   
  where 
     simpleStage cp = Stage cp simpleLinePolicy simpleErrorPolicy
     simpleSubsequentStage = SubsequentStage (FalliblePipe P.cat) . simpleStage
     simpleLinePolicy = linePolicy decoder (pure ()) id
     simpleErrorPolicy = Just . ("Exit failure: " ++) . show

executePipelineInternal :: (Show e,Typeable e) 
                        => (Siphon ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> (Pump ByteString e () -> Siphon ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> (Pump ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> (Pump ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> CreatePipeline e 
                        -> IO (Either e ())
executePipelineInternal ppinitial ppmiddle ppend ppend' (CreatePipeline (Stage cp lpol ecpol) a) =      
    blende ecpol <$> executeFallibly (ppinitial (runNonEmpty ppend ppend' a) lpol) cp
  where 
    runTree ppend ppend' (Node (SubsequentStage (FalliblePipe pipe) (Stage cp lpol ecpol)) forest) = case forest of
        [] -> Siphon $ \producer ->
            blende ecpol <$> executeFallibly (ppend (fromFallibleProducer $ hoist lift producer >-> pipe) lpol) cp
        c1 : cs -> Siphon $ \producer ->
           blende ecpol <$> executeFallibly (ppmiddle (fromFallibleProducer $ hoist lift producer >-> pipe) (runNonEmpty ppend ppend' (c1 :| cs)) lpol) cp

    runNonEmpty ppend ppend' (b :| bs) = 
        runTree ppend ppend' b <* Prelude.foldr (<*) (pure ()) (runTree ppend' ppend' <$> bs) 
    
    blende :: (Int -> Maybe e) -> Either e (ExitCode,()) -> Either e ()
    blende f (Right (ExitFailure i,())) = case f i of
        Nothing -> Right ()
        Just e -> Left e
    blende _ (Right (ExitSuccess,())) = Right () 
    blende _ (Left e) = Left e

{- $reexports
 
"System.Process" is re-exported for convenience.

-} 

