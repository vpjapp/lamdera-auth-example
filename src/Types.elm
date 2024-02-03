module Types exposing (..)

import Auth.Common exposing (UserInfo)
import Browser exposing (UrlRequest)
import Browser.Navigation exposing (Key)
import Dict exposing (Dict)
import Lamdera exposing (SessionId)
import Url exposing (Url)


type LoginState
    = NotLogged
    | LoginTokenSent
    | LoggedIn UserInfo


type alias FrontendModel =
    { login : LoginState
    , key : Key
    , authFlow : Auth.Common.Flow
    , authRedirectBaseUrl : Url
    }


type alias BackendModel =
    { message : String
    , pendingAuths : Dict Lamdera.SessionId Auth.Common.PendingAuth
    , sessions : Dict SessionId UserInfo
    }


type FrontendMsg
    = UrlClicked UrlRequest
    | UrlChanged Url
    | NoOpFrontendMsg
    | GoogleSigninRequested
    | Logout


type ToBackend
    = NoOpToBackend
    | AuthToBackend Auth.Common.ToBackend
    | GetUser
    | LoggedOut


type BackendMsg
    = NoOpBackendMsg
    | AuthBackendMsg Auth.Common.BackendMsg


type ToFrontend
    = NoOpToFrontend
    | AuthToFrontend Auth.Common.ToFrontend
    | AuthSuccess UserInfo
    | UserInfoMsg (Maybe UserInfo)
