{-# OPTIONS -Wall #-}

-- | Main socket server.

module Server.Server where

import Data.IORef
import Server.Client
import Server.Commands
import Server.Import
import Server.Slave

import System.IO

-- | Start a server.
startAccepter :: IO ()
startAccepter =
  do main <- myThreadId
     server <- newServer main
     socket <- listenOn (PortNumber port)
     logger (Notice ("Listening on port " ++ show port ++ " ..."))
     connections <- newIORef []
     finally (forever (do (h,host,remotePort) <- accept socket
                          forkIO (do tid <- myThreadId
                                     modifyIORef connections ((tid,h) :)
                                     startClient h host remotePort server)))
             (do cons <- readIORef connections
                 logger (Fatal "Server killed!")
                 mapM_ (\(tid,h) ->
                          do logger (Debug ("Killing " ++ show tid ++ " ..."))
                             killThread tid
                             logger (Debug ("Killing connection " ++ show h ++ " ..."))
                             hClose h)
                       cons
                 sClose socket
                 logger (Debug ("Closed listener on port " ++ show port)))
  where port = 5233

-- | Make a new server that will receive commands concurrently and
-- respond, asynchronously, concurrently.
newServer :: ThreadId -> IO Server
newServer main =
  do slave <- newSlave main
     inChan <- newChan
     -- Launch a command-accepting loop
     tid <- forkIO (forever (do (cmd,replyChan) <- io (readChan inChan)
                                newRequest slave cmd replyChan))
     return (Server inChan tid slave)

-- | Launch a command handler, may be queued up in GHC or run
-- immediately.
newRequest :: Slave -> Cmd -> Chan ResultType -> IO ThreadId
newRequest slave cmd resultsChan =
  forkIO (do let onError e = writeChan resultsChan (ErrorResult e)
                 withGHC m = writeChan (slaveIn slave) (onError,m)
             clientCall withGHC cmd resultsChan)
