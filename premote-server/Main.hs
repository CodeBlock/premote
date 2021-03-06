{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Applicative ((<$>))
import Control.Monad
import Control.Monad.IO.Class
import Data.IORef
import Data.Monoid
import qualified Data.Text as T
import Data.String (fromString)
import Data.Word (Word64)
import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras
import Network.Info
import Network.Wai (Application)
import Network.Wai.Handler.Warp
import Network.Wai.Handler.WarpTLS (certFile, defaultTlsSettings,
                                    keyFile, runTLS)
import Web.Scotty
import Web.Scotty.Cookie
import System.Environment
import System.Random

-- | Send a key to a given window (on a given rootwindow, on a given display).
sendKey :: Display -> Window -> Window -> KeyMask -> KeySym -> IO ()
sendKey display rootwindow window keymask keysym = allocaXEvent $ \event -> do
  kc <- keysymToKeycode display keysym
  setEventType event keyPress
  setKeyEvent event window rootwindow none keymask kc True
  sendEvent display window True keyPressMask event
  setEventType event keyRelease
  sendEvent display window True keyReleaseMask event
  flush display

showInterfaces :: IO [(Int, NetworkInterface)]
showInterfaces = do
  interfaces <- zip [1..] <$> getNetworkInterfaces
  mapM_ (\(a, b) -> putStrLn $ showInterface a b) interfaces
  return interfaces
  where
    showInterface n i =
      show n <> ". " <> name i <> " (" <> show (ipv4 i) <> ")"

getSelection :: [(Int, NetworkInterface)] -> Int -> IO NetworkInterface
getSelection interfaces selection = do
  let selected = filter (\(a, _) -> a == selection) interfaces
  if length selected /= 1
    then do putStrLn "Invalid selection! Try again!"
            selection' <- read <$> getLine :: IO Int
            getSelection interfaces selection'
    else let selected' = snd . head $ selected
         in do
           putStrLn $ "Binding to " <> show (ipv4 selected')
           return selected'

main :: IO ()
main = do
  args <- getArgs
  -- TODO: Use Maybe here.
  when (length args /= 1) (error "Use `xwininfo` to get your window id and supply it as an argument to this program.")
  let windowId = read $ head args

  putStrLn "Please select an interface to bind to."
  interfaces <- showInterfaces
  selection <- read <$> getLine :: IO Int
  interface <- getSelection interfaces selection
  d <- liftIO $ openDisplay ""
  rw <- liftIO $ rootWindow d $ defaultScreen d
  let settings' = setHost (fromString (show (ipv4 interface))) defaultSettings
  app <- endpoints d rw windowId
  {-runTLS
    (defaultTlsSettings { keyFile = "server.key" , certFile = "server.crt" })
    settings'
    app
  -}
  runSettings settings' app


endpoints :: Display -> Window -> Word64 -> IO Application
endpoints d w wid = scottyApp $ do
  sessionId <- liftIO $ mapM (\_ -> randomRIO ('a', 'z')) ([1..1000] :: [Int])
  boundToSessionId <- liftIO $ newIORef False
  get "/noop" $ do
    -- Exists for clients to get a cookie without actually doing anything.
    sId <- getCookie "sessionid"
    checkSession boundToSessionId sId (T.pack sessionId)
    text "welcome"
  get "/page-up" $ do
    sId <- getCookie "sessionid"
    checkSession boundToSessionId sId (T.pack sessionId)
    sendKey' noModMask xK_Page_Up
    text "done"
  get "/page-down" $ do
    sId <- getCookie "sessionid"
    checkSession boundToSessionId sId (T.pack sessionId)
    sendKey' noModMask xK_Page_Down
    text "done"
  where
    sendKey' mask sym = liftIO $ sendKey d w wid mask sym
    checkSessionId original given = maybe False (original ==) given
    checkSession bound givenId originalId = do
      isBound <- liftIO $ readIORef bound :: ActionM Bool
      when (isBound && not (checkSessionId originalId givenId)) $ do
        liftIO $ putStrLn "Invalid session ID received"
        raise "Invalid session ID"
      setSimpleCookie "sessionid" originalId
      liftIO $ writeIORef bound True
