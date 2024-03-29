module Backend exposing (..)

import Auth
import Auth.Common exposing (UserInfo)
import Auth.Flow
import Dict exposing (Dict)
import Lamdera exposing (ClientId, SessionId)
import Types exposing (BackendModel, BackendMsg(..), ToBackend(..), ToFrontend(..))


type alias Model =
    BackendModel


app =
    Lamdera.backend
        { init = init
        , update = update
        , updateFromFrontend = updateFromFrontend
        , subscriptions = \m -> Sub.none
        }


init : ( Model, Cmd BackendMsg )
init =
    ( { message = "Hello!"
      , pendingAuths = Dict.empty
      , sessions = Dict.empty
      }
    , Cmd.none
    )


update : BackendMsg -> Model -> ( Model, Cmd BackendMsg )
update msg model =
    case msg of
        NoOpBackendMsg ->
            ( model, Cmd.none )

        AuthBackendMsg authMsg ->
            let
                _ =
                    Debug.log "AUTH BACKEND msg" authMsg
            in
            Auth.Flow.backendUpdate (Auth.backendConfig model) authMsg


updateFromFrontend : SessionId -> ClientId -> ToBackend -> Model -> ( Model, Cmd BackendMsg )
updateFromFrontend sessionId clientId msg model =
    case msg of
        NoOpToBackend ->
            ( model, Cmd.none )

        AuthToBackend authMsg ->
            Auth.Flow.updateFromFrontend (Auth.backendConfig model) clientId sessionId authMsg model

        GetUser ->
            ( model, Lamdera.sendToFrontend clientId <| UserInfoMsg (findUser sessionId model) )

        LoggedOut ->
            ( { model | sessions = removeSession sessionId model.sessions }, Cmd.none )


removeSession : SessionId -> Dict SessionId UserInfo -> Dict SessionId UserInfo
removeSession sessionId sessions =
    Dict.remove sessionId sessions


findUser : SessionId -> Model -> Maybe Auth.Common.UserInfo
findUser sessionId model =
    Dict.get sessionId model.sessions
