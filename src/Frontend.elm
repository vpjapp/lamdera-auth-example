module Frontend exposing (..)

import Auth
import Auth.Common exposing (Flow(..))
import Auth.Flow
import Browser exposing (UrlRequest(..))
import Browser.Navigation as Nav
import Html exposing (Html, button, div, label, text)
import Html.Events exposing (onClick)
import Lamdera exposing (Url, sendToBackend)
import Types exposing (..)
import Url


type alias Model =
    FrontendModel


app =
    Lamdera.frontend
        { init = init
        , onUrlRequest = UrlClicked
        , onUrlChange = UrlChanged
        , update = update
        , updateFromBackend = updateFromBackend
        , subscriptions = \_ -> Sub.none
        , view = view
        }


init : Url.Url -> Nav.Key -> ( Model, Cmd FrontendMsg )
init url key =
    let
        model =
            { key = key
            , login = NotLogged
            , authFlow = Idle
            , authRedirectBaseUrl = { url | query = Nothing, fragment = Nothing }
            }
    in
    authCallbackCmd model url key
        |> Tuple.mapSecond (\cmd -> Cmd.batch [ cmd, Lamdera.sendToBackend GetUser ])


authCallbackCmd : Model -> Url -> Nav.Key -> ( Model, Cmd FrontendMsg )
authCallbackCmd model url key =
    let
        { path } =
            url
    in
    case path of
        "/login/OAuthGoogle/callback" ->
            callbackForGoogleAuth model url key

        _ ->
            let
                _ =
                    Debug.log "Auth callback" ("Did not match Path:" ++ path ++ " Url:" ++ Url.toString url)
            in
            ( model, Cmd.none )


callbackForGoogleAuth : Model -> Url -> Nav.Key -> ( Model, Cmd FrontendMsg )
callbackForGoogleAuth model url key =
    let
        ( authM, authCmd ) =
            Auth.Flow.init model
                "OAuthGoogle"
                url
                key
                (\msg -> Lamdera.sendToBackend (AuthToBackend msg))
    in
    ( authM, authCmd )


update : FrontendMsg -> Model -> ( Model, Cmd FrontendMsg )
update msg model =
    case msg of
        UrlClicked urlRequest ->
            case urlRequest of
                Internal url ->
                    ( model
                    , Nav.pushUrl model.key (Url.toString url)
                    )

                External url ->
                    ( model
                    , Nav.load url
                    )

        UrlChanged _ ->
            ( model, Cmd.none )

        NoOpFrontendMsg ->
            ( model, Cmd.none )

        GoogleSigninRequested ->
            Auth.Flow.signInRequested "OAuthGoogle" model Nothing
                |> Tuple.mapSecond (AuthToBackend >> sendToBackend)

        Logout ->
            ( { model | login = NotLogged }, Lamdera.sendToBackend LoggedOut )


noCmd : Model -> ( Model, Cmd FrontendMsg )
noCmd model =
    ( model, Cmd.none )


updateFromBackend : ToFrontend -> Model -> ( Model, Cmd FrontendMsg )
updateFromBackend msg model =
    case msg of
        NoOpToFrontend ->
            ( model, Cmd.none )

        AuthToFrontend authMsg ->
            Auth.updateFromBackend authMsg model

        AuthSuccess userInfo ->
            ( { model | login = LoggedIn userInfo }, Nav.pushUrl model.key "/" )

        UserInfoMsg mUserinfo ->
            case mUserinfo of
                Just userInfo ->
                    ( { model | login = LoggedIn userInfo }, Cmd.none )

                Nothing ->
                    ( { model | login = NotLogged }, Cmd.none )


view : Model -> Browser.Document FrontendMsg
view model =
    { title = "Lamdera Auth Example"
    , body =
        [ case model.login of
            NotLogged ->
                viewNotLogged

            LoginTokenSent ->
                viewTokenSent

            LoggedIn user ->
                div []
                    [ text user.email
                    , text " "
                    , label []
                        [ button [ onClick Logout ] [ text "Logout" ] ]
                    ]
        ]
    }


viewTokenSent : Html FrontendMsg
viewTokenSent =
    div []
        [ text "Token has been sent"
        ]


viewNotLogged : Html FrontendMsg
viewNotLogged =
    div []
        [ label []
            [ button [ onClick GoogleSigninRequested ] [ text "Login with Google" ] ]
        ]
