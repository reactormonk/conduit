{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Defines the types for a sink, which is a consumer of data.
module Data.Conduit.Types.Sink
    ( SinkResult (..)
    , PureSink (..)
    , Sink (..)
    , Result (..)
    ) where

import Control.Monad.Trans.Resource
import Control.Monad.Trans.Class (MonadTrans (lift))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad (liftM)
import Control.Applicative (Applicative (..))
import Control.Monad.Base (MonadBase (liftBase))

data Result a = Processing | Done a
instance Functor Result where
    fmap _ Processing = Processing
    fmap f (Done a) = Done (f a)

-- | At the end of running, a 'Sink' returns some leftover input and an output.
data SinkResult input output = SinkResult [input] output
instance Functor (SinkResult input) where
    fmap f (SinkResult input output) = SinkResult input (f output)

-- | In general, a sink will consume data and eventually produce an output when
-- it has consumed \"enough\" data. There are two caveats to that statement:
--
-- * Some sinks do not actually require any data to produce an output. This is
-- included with a sink in order to allow for a 'Monad' instance.
--
-- * Some sinks will consume all available data and only produce a result at
-- the \"end\" of a data stream (e.g., @sum@).
--
-- To allow for the first caveat, we have the 'SinkNoData' constructor. For the
-- second, the 'SinkData' constructor has two records: one for receiving more
-- input, and the other to indicate the end of a stream. Note that, at the end
-- of a stream, some output is required. If a specific 'Sink' implementation
-- cannot always produce output, this should be indicated in its return value,
-- using something like a 'Maybe' or 'Either'.
--
-- Invariants:
--
-- * After a 'Sink' produces a result (either via 'sinkPush' or 'sinkClose'),
-- neither of those two functions may be called on the @Sink@ again.
--
-- * If a @Sink@ needs to clean up any resources (e.g., close a file handle),
-- it must do so whenever it returns a result, either via @sinkPush@ or
-- @sinkClose@.
data PureSink input m output =
    SinkNoData output
  | SinkData
        { sinkPush :: [input] -> ResourceT m (Result (SinkResult input output))
        , sinkClose :: [input] -> ResourceT m (SinkResult input output)
        }

instance Monad m => Functor (PureSink input m) where
    fmap f (SinkNoData x) = SinkNoData (f x)
    fmap f (SinkData p c) = SinkData
        { sinkPush = liftM (fmap (fmap f)) . p
        , sinkClose = liftM (fmap f) . c
        }

-- | Most 'Sink's require some type of state, similar to 'Source's. Like a
-- @SourceM@ for a @Source@, a @Sink@ is a simple monadic wrapper around a
-- @Sink@ which allows initialization of such state. See @SourceM@ for further
-- caveats.
--
-- Note that this type provides a 'Monad' instance, allowing you to easily
-- compose @Sink@s together.
newtype Sink input m output = Sink { genSink :: ResourceT m (PureSink input m output) }

instance Monad m => Functor (Sink input m) where
    fmap f (Sink msink) = Sink (liftM (fmap f) msink)

instance Resource m => Applicative (Sink input m) where
    pure x = Sink (return (SinkNoData x))
    Sink mf <*> Sink ma = Sink $ do
        f <- mf
        a <- ma
        case (f, a) of
            (SinkNoData f', SinkNoData a') -> return (SinkNoData (f' a'))
            _ -> do
                istate <- newRef (toEither f, toEither a)
                return $ appHelper istate

toEither :: PureSink input m output -> SinkEither input m output
toEither (SinkData x y) = SinkPair x y
toEither (SinkNoData x) = SinkOutput x

type SinkPush input m output = [input] -> ResourceT m (Result (SinkResult input output))
type SinkClose input m output = [input] -> ResourceT m (SinkResult input output)
data SinkEither input m output
    = SinkPair (SinkPush input m output) (SinkClose input m output)
    | SinkOutput output
type SinkState input m a b = Ref (Base m) (SinkEither input m (a -> b), SinkEither input m a)

appHelper :: Resource m => SinkState input m a b -> PureSink input m b
appHelper istate = SinkData (pushHelper istate) (closeHelper istate)

pushHelper :: Resource m
           => SinkState input m a b
           -> [input]
           -> ResourceT m (Result (SinkResult input b))
pushHelper istate stream0 = do
    state <- readRef istate
    go state stream0
  where
    go (SinkPair f _, eb) stream = do
        mres <- f stream
        case mres of
            Processing -> return Processing
            Done (SinkResult leftover res) -> do
                let state' = (SinkOutput res, eb)
                writeRef istate state'
                go state' leftover
    go (f@SinkOutput{}, SinkPair b _) stream = do
        mres <- b stream
        case mres of
            Processing -> return Processing
            Done (SinkResult leftover res) -> do
                let state' = (f, SinkOutput res)
                writeRef istate state'
                go state' leftover
    go (SinkOutput f, SinkOutput b) leftover = return $ Done $ SinkResult leftover $ f b

closeHelper :: Resource m
            => SinkState input m a b
            -> [input]
            -> ResourceT m (SinkResult input b)
closeHelper istate input0 = do
    (sf, sa) <- readRef istate
    case sf of
        SinkOutput f -> go' f sa input0
        SinkPair _ close -> do
            SinkResult leftover f <- close input0
            go' f sa leftover
  where
    go' f (SinkPair _ close) input = do
        SinkResult leftover a <- close input
        return $ SinkResult leftover (f a)
    go' f (SinkOutput a) input = return $ SinkResult input (f a)

instance Resource m => Monad (Sink input m) where
    return = pure
    x >>= f = sinkJoin (fmap f x)

instance (Resource m, Base m ~ base, Applicative base) => MonadBase base (Sink input m) where
    liftBase = lift . resourceLiftBase

instance MonadTrans (Sink input) where
    lift f = Sink (lift (liftM SinkNoData f))

instance (Resource m, MonadIO m) => MonadIO (Sink input m) where
    liftIO = lift . liftIO

sinkJoin :: Resource m => Sink a m (Sink a m b) -> Sink a m b
sinkJoin (Sink msink) = Sink $ do
    sink <- msink
    case sink of
        SinkNoData (Sink inner) -> inner
        SinkData pushO closeO -> do
            istate <- newRef Processing
            return $ SinkData (push istate pushO) (close istate closeO)
  where
    push istate pushO stream = do
        state <- readRef istate
        case state of
            Done (pushI, _) -> pushI stream
            Processing -> do
                minner' <- pushO stream
                case minner' of
                    Processing -> return Processing
                    Done (SinkResult leftover (Sink msink')) -> do
                        sink <- msink'
                        case sink of
                            SinkData pushI closeI -> do
                                writeRef istate $ Done (pushI, closeI)
                                if null leftover
                                    then return Processing
                                    else push istate pushO leftover
                            SinkNoData x -> return $ Done $ SinkResult leftover x
    close istate closeO input = do
        state <- readRef istate
        case state of
            Done (_, closeI) -> closeI input
            Processing -> do
                SinkResult leftover (Sink minner) <- closeO input
                inner <- minner
                case inner of
                    SinkData _ closeI -> closeI leftover
                    SinkNoData x -> return $ SinkResult leftover x
