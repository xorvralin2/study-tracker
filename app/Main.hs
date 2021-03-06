{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}


import Web.Spock
import Web.Spock.Config

import Data.Aeson hiding (json)
import Data.Monoid ((<>))
import Data.Text (Text, pack, unpack)
import System.FilePath (takeExtension, takeFileName)
import Data.List (isPrefixOf)
import GHC.Generics


import           Control.Monad.Logger    (LoggingT, runStdoutLoggingT)
import           Control.Monad.IO.Class
import           Database.Persist        hiding (get) -- To avoid a naming clash with Web.Spock.get
import qualified Database.Persist        as P         -- We'll be using P.get later for GET /people/<id>.
import           Database.Persist.Sqlite hiding (get)
import           Database.Persist.TH

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Person json
    name Text
    age Int
    deriving Show
|]

type Api = SpockM SqlBackend () () ()

type ApiAction a = SpockAction SqlBackend () () a

main :: IO ()
main = do
    pool <- runStdoutLoggingT $ createSqlitePool "api.db" 5
    spockCfg <- defaultSpockCfg () (PCPool pool) ()
    runStdoutLoggingT $ runSqlPool (do runMigration migrateAll) pool
    runSpock 8080 (spock spockCfg app)

app :: Api
app = do
    get root $ do
        file (pack "text/html; charset=utf-8") "public/index.html"

    get ("/" <//> wildcard) $ \route -> do
        let path = unpack route
        let reqType = getRequestType path
        file (pack (getHttpHeader reqType)) ("public/" ++ path)


    get "people" $ do
        allPeople <- runSql $ selectList [] [Asc PersonId] -- SELECT but returns a list
        json allPeople
    get ("people" <//> var) $ \personId -> do
        maybePerson <- runSql $ P.get personId :: ApiAction (Maybe Person)
        case maybePerson of
            Nothing -> errorJson 2 "Could not find a person with mathcing id"
            Just thePerson -> json thePerson
    post "people" $ do
        maybePerson <- jsonBody :: ApiAction (Maybe Person)
        case maybePerson of
            -- Pattern match Maybe constructors
            Nothing -> errorJson 1 "Failed to parse request body as Person"
            Just thePerson -> do
                newId <- runSql $ insert thePerson
                json $ object ["result" .= String "success", "id" .= newId]

runSql :: (HasSpock m, SpockConn m ~ SqlBackend) => SqlPersistT (LoggingT IO) a -> m a
runSql action = runQuery $ \conn -> runStdoutLoggingT $ runSqlConn action conn

errorJson :: Int -> Text -> ApiAction ()
errorJson code message = 
    json $
        object
        [ "result" .= String "failure"
        , "error" .= object ["code" .= code, "message" .= message] -- (.=) constructs a Pair
        ]

apiPrint :: String -> ApiAction ()
apiPrint str = liftIO $ putStrLn str

data RequestType = Html | Css | Js | Image String | Json | Plain
    deriving (Show, Eq)

imageFileEndings = ["gif", "png", "jpg", "jpeg", "svg"]

getRequestType :: String -> RequestType
getRequestType route 
    | ending `elem` imageFileEndings = Image ending
    | ending == "html" = Html
    | ending == "css" = Css
    | ending == "js" = Js
    | otherwise = Plain
    where ending = tail $ takeExtension route

getHttpHeader :: RequestType -> String
getHttpHeader req = case req of
                      Html  -> "text/html; charset=utf-8"
                      Css   -> "text/css; charset=utf-8"
                      Js    -> "application/javascript; charset=utf-8"
                      Image "svg" -> "image/svg+xml; charset=utf-8"
                      Image ending -> "image/" ++ ending ++ "; charset=utf-8"
                      Json -> "text/plain; charset=utf-8" -- TODO: Fix
                      Plain -> "text/plain; charset=utf-8"
