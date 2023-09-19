module OAuth.AuthorizationCode.PKCE exposing
    ( CodeVerifier(..), CodeChallenge(..), codeVerifierFromBytes, codeVerifierToString, mkCodeChallenge, codeChallengeToString
    , makeAuthorizationUrl, Authorization, parseCode, AuthorizationResult, AuthorizationError, AuthorizationSuccess, AuthorizationCode
    , makeTokenRequest, Authentication, Credentials, AuthenticationSuccess, AuthenticationError, RequestParts
    , defaultAuthenticationSuccessDecoder, defaultAuthenticationErrorDecoder
    , makeAuthorizationUrlWith, AuthorizationResultWith(..)
    , makeTokenRequestWith
    , defaultExpiresInDecoder, defaultScopeDecoder, lenientScopeDecoder, defaultTokenDecoder, defaultRefreshTokenDecoder, defaultErrorDecoder, defaultErrorDescriptionDecoder, defaultErrorUriDecoder
    , parseCodeWith, Parsers, defaultParsers, defaultCodeParser, defaultErrorParser, defaultAuthorizationSuccessParser, defaultAuthorizationErrorParser
    )

{-| OAuth 2.0 public clients utilizing the Authorization Code Grant are
susceptible to the authorization code interception attack. A possible
mitigation against the threat is to use a technique called Proof Key for
Code Exchange (PKCE, pronounced "pixy") when supported by the target
authorization server. See also [RFC 7636](https://tools.ietf.org/html/rfc7636).


## Quick Start

To get started, have a look at the [live-demo](https://truqu.github.io/elm-oauth2/auth0/pkce/) and its corresponding [source
code](https://github.com/truqu/elm-oauth2/blob/master/examples/providers/auth0/pkce/Main.elm)


## Overview

                                         +-----------------+
                                         |  Auth   Server  |
        +-------+                        | +-------------+ |
        |       |--(1)- Auth Request --->| |             | |
        |       |    + code_challenge    | |    Auth     | |
        |       |                        | |   Endpoint  | |
        |       |<-(2)-- Auth Code ------| |             | |
        |  Elm  |                        | +-------------+ |
        |  App  |                        |                 |
        |       |                        | +-------------+ |
        |       |--(3)- Token Request -->| |             | |
        |       |      + code_verifier   | |   Token     | |
        |       |                        | |  Endpoint   | |
        |       |<-(4)- Access Token --->| |             | |
        +-------+                        | +-------------+ |
                                         +-----------------+

See also the Authorization Code flow for details about the basic version
of this flow.


## Code Verifier / Challenge

@docs CodeVerifier, CodeChallenge, codeVerifierFromBytes, codeVerifierToString, mkCodeChallenge, codeChallengeToString


## Authorize

@docs makeAuthorizationUrl, Authorization, parseCode, AuthorizationResult, AuthorizationError, AuthorizationSuccess, AuthorizationCode


## Authenticate

@docs makeTokenRequest, Authentication, Credentials, AuthenticationSuccess, AuthenticationError, RequestParts


## JSON Decoders

@docs defaultAuthenticationSuccessDecoder, defaultAuthenticationErrorDecoder


## Custom Decoders & Parsers (advanced)


### Authorize

@docs makeAuthorizationUrlWith, AuthorizationResultWith


### Authenticate

@docs makeTokenRequestWith


### Json Decoders

@docs defaultExpiresInDecoder, defaultScopeDecoder, lenientScopeDecoder, defaultTokenDecoder, defaultRefreshTokenDecoder, defaultErrorDecoder, defaultErrorDescriptionDecoder, defaultErrorUriDecoder


### Query Parsers

@docs parseCodeWith, Parsers, defaultParsers, defaultCodeParser, defaultErrorParser, defaultAuthorizationSuccessParser, defaultAuthorizationErrorParser

-}

import Base64.Encode as Base64
import Bytes exposing (Bytes)
import Dict as Dict exposing (Dict)
import Effect.Http
import Internal as Internal exposing (..)
import Json.Decode as Json
import OAuth exposing (ErrorCode, GrantType(..), ResponseType(..), Token, errorCodeFromString)
import OAuth.AuthorizationCode
import SHA256 as SHA256
import Url exposing (Url)
import Url.Builder as Builder
import Url.Parser as Url exposing ((<?>))
import Url.Parser.Query as Query



--
-- Code Challenge / Code Verifier
--


{-| An opaque type representing a code verifier. Typically constructed from a high quality entropy.

    case codeVerifierFromBytes entropy of
      Nothing -> {- ...-}
      Just codeVerifier -> {- ... -}

-}
type CodeVerifier
    = CodeVerifier Base64.Encoder


{-| An opaque type representing a code challenge. Typically constructed from a `CodeVerifier`.

    let codeChallenge = mkCodeChallenge codeVerifier

-}
type CodeChallenge
    = CodeChallenge Base64.Encoder


{-| Construct a code verifier from a byte sequence generated from a **high quality randomness** source (i.e. cryptographic).

Ideally, the byte sequence _should be_ 32 or 64 bytes, and it _must be_ at least 32 bytes and at most 90 bytes.

-}
codeVerifierFromBytes : Bytes -> Maybe CodeVerifier
codeVerifierFromBytes bytes =
    if Bytes.width bytes < 32 || Bytes.width bytes > 90 then
        Nothing

    else
        bytes |> Base64.bytes |> CodeVerifier |> Just


{-| Convert a code verifier to its string representation.
-}
codeVerifierToString : CodeVerifier -> String
codeVerifierToString (CodeVerifier str) =
    base64UrlEncode str


{-| Construct a `CodeChallenge` to send to the authorization server. Upon receiving the authorization code, the client can then
the associated `CodeVerifier` to prove it is the rightful owner of the authorization code.
-}
mkCodeChallenge : CodeVerifier -> CodeChallenge
mkCodeChallenge =
    codeVerifierToString >> SHA256.fromString >> SHA256.toBytes >> Base64.bytes >> CodeChallenge


{-| Convert a code challenge to its string representation.
-}
codeChallengeToString : CodeChallenge -> String
codeChallengeToString (CodeChallenge str) =
    base64UrlEncode str


{-| Internal function implementing Base64-URL encoding (i.e. base64 without padding and some unsuitable characters replaced)
-}
base64UrlEncode : Base64.Encoder -> String
base64UrlEncode =
    Base64.encode
        >> String.replace "=" ""
        >> String.replace "+" "-"
        >> String.replace "/" "_"



--
-- Authorize
--


{-| Request configuration for an authorization (Authorization Code & Implicit flows)

  - `clientId` (_REQUIRED_):
    The client identifier issues by the authorization server via an off-band mechanism.

  - `url` (_REQUIRED_):
    The authorization endpoint to contact the authorization server.

  - `redirectUri` (_OPTIONAL_):
    After completing its interaction with the resource owner, the authorization
    server directs the resource owner's user-agent back to the client via this
    URL. May be already defined on the authorization server itself.

  - `scope` (_OPTIONAL_):
    The scope of the access request.

  - `state` (_RECOMMENDED_):
    An opaque value used by the client to maintain state between the request
    and callback. The authorization server includes this value when redirecting
    the user-agent back to the client. The parameter SHOULD be used for preventing
    cross-site request forgery.

  - `codeChallenge` (_REQUIRED_):
    A challenge derived from the code verifier that is sent in the
    authorization request, to be verified against later.

-}
type alias Authorization =
    { clientId : String
    , url : Url
    , redirectUri : Url
    , scope : List String
    , state : Maybe String
    , codeChallenge : CodeChallenge
    }


{-| Describes an OAuth error as a result of an authorization request failure

  - `error` (_REQUIRED_):
    A single ASCII error code.

  - `errorDescription` (_OPTIONAL_)
    Human-readable ASCII text providing additional information, used to assist the client developer in
    understanding the error that occurred. Values for the `errorDescription` parameter MUST NOT
    include characters outside the set `%x20-21 / %x23-5B / %x5D-7E`.

  - `errorUri` (_OPTIONAL_):
    A URI identifying a human-readable web page with information about the error, used to
    provide the client developer with additional information about the error. Values for the
    `errorUri` parameter MUST conform to the URI-reference syntax and thus MUST NOT include
    characters outside the set `%x21 / %x23-5B / %x5D-7E`.

  - `state` (_REQUIRED if `state` was present in the authorization request_):
    The exact value received from the client

-}
type alias AuthorizationError =
    { error : ErrorCode
    , errorDescription : Maybe String
    , errorUri : Maybe String
    , state : Maybe String
    }


{-| The response obtained as a result of an authorization

  - `code` (_REQUIRED_):
    The authorization code generated by the authorization server. The authorization code MUST expire
    shortly after it is issued to mitigate the risk of leaks. A maximum authorization code lifetime of
    10 minutes is RECOMMENDED. The client MUST NOT use the authorization code more than once. If an
    authorization code is used more than once, the authorization server MUST deny the request and
    SHOULD revoke (when possible) all tokens previously issued based on that authorization code. The
    authorization code is bound to the client identifier and redirection URI.

  - `state` (_REQUIRED if `state` was present in the authorization request_):
    The exact value received from the client

-}
type alias AuthorizationSuccess =
    { code : String
    , state : Maybe String
    }


{-| Describes errors coming from attempting to parse a url after an OAuth redirection
-}
type alias AuthorizationResult =
    AuthorizationResultWith AuthorizationError AuthorizationSuccess


{-| A parameterized [`AuthorizationResult`](#AuthorizationResult), see [`parseTokenWith`](#parseTokenWith).

  - `Empty`: means there were nothing (related to OAuth 2.0) to parse
  - `Error`: a successfully parsed OAuth 2.0 error
  - `Success`: a successfully parsed token and response

-}
type AuthorizationResultWith error success
    = Empty
    | Error error
    | Success success


{-| Redirects the resource owner (user) to the resource provider server using the specified
authorization flow.
-}
makeAuthorizationUrl : Authorization -> Url
makeAuthorizationUrl =
    makeAuthorizationUrlWith Code Dict.empty


{-| Parse the location looking for a parameters set by the resource provider server after
redirecting the resource owner (user).

Returns `AuthorizationResult Empty` when there's nothing.

-}
parseCode : Url -> AuthorizationResult
parseCode =
    parseCodeWith defaultParsers



--
-- Authenticate
--


{-| Request configuration for an AuthorizationCode authentication

  - `credentials` (_REQUIRED_):
    Only the clientId is required. Specify a secret if a Basic OAuth
    is required by the resource provider.

  - `code` (_REQUIRED_):
    Authorization code from the authorization result

  - `codeVerifier` (_REQUIRED_):
    The code verifier proving you are the rightful recipient of the
    access token.

  - `url` (_REQUIRED_):
    Token endpoint of the resource provider

  - `redirectUri` (_REQUIRED_):
    Redirect Uri to your webserver used in the authorization step, provided
    here for verification.

-}
type alias Authentication =
    { credentials : Credentials
    , code : String
    , codeVerifier : CodeVerifier
    , redirectUri : Url
    , url : Url
    }


{-| The response obtained as a result of an authentication (implicit or not)

  - `token` (_REQUIRED_):
    The access token issued by the authorization server.

  - `refreshToken` (_OPTIONAL_):
    The refresh token, which can be used to obtain new access tokens using the same authorization
    grant as described in [Section 6](https://tools.ietf.org/html/rfc6749#section-6).

  - `expiresIn` (_RECOMMENDED_):
    The lifetime in seconds of the access token. For example, the value "3600" denotes that the
    access token will expire in one hour from the time the response was generated. If omitted, the
    authorization server SHOULD provide the expiration time via other means or document the default
    value.

  - `scope` (_OPTIONAL, if identical to the scope requested; otherwise, REQUIRED_):
    The scope of the access token as described by [Section 3.3](https://tools.ietf.org/html/rfc6749#section-3.3).

-}
type alias AuthenticationSuccess =
    { token : Token
    , refreshToken : Maybe Token
    , expiresIn : Maybe Int
    , scope : List String
    }


{-| A simple type alias to ease readability of type signatures
-}
type alias AuthorizationCode =
    String


{-| Describes an OAuth error as a result of a request failure

  - `error` (_REQUIRED_):
    A single ASCII error code.

  - `errorDescription` (_OPTIONAL_)
    Human-readable ASCII text providing additional information, used to assist the client developer in
    understanding the error that occurred. Values for the `errorDescription` parameter MUST NOT
    include characters outside the set `%x20-21 / %x23-5B / %x5D-7E`.

  - `errorUri` (_OPTIONAL_):
    A URI identifying a human-readable web page with information about the error, used to
    provide the client developer with additional information about the error. Values for the
    `errorUri` parameter MUST conform to the URI-reference syntax and thus MUST NOT include
    characters outside the set `%x21 / %x23-5B / %x5D-7E`.

-}
type alias AuthenticationError =
    { error : ErrorCode
    , errorDescription : Maybe String
    , errorUri : Maybe String
    }


{-| Parts required to build a request. This record is given to [`Http.request`](https://package.elm-lang.org/packages/elm/http/latest/Http#request)
in order to create a new request and may be adjusted at will.
-}
type alias RequestParts a =
    { method : String
    , headers : List Effect.Http.Header
    , url : String
    , body : Effect.Http.Body
    , expect : Effect.Http.Expect a
    , timeout : Maybe Float
    , tracker : Maybe String
    }


{-| Describes at least a `clientId` and if define, a complete set of credentials
with the `secret`. The secret is so-to-speak optional and depends on whether the
authorization server you interact with requires a Basic authentication on top of
the authentication request. Provides it if you need to do so.

      { clientId = "<my-client-id>"
      , secret = Just "<my-client-secret>"
      }

-}
type alias Credentials =
    { clientId : String
    , secret : Maybe String
    }


{-| Builds a the request components required to get a token from an authorization code

    let req : Http.Request AuthenticationSuccess
        req = makeTokenRequest toMsg authentication |> Http.request

-}
makeTokenRequest : (Result Effect.Http.Error AuthenticationSuccess -> msg) -> Authentication -> RequestParts msg
makeTokenRequest =
    makeTokenRequestWith AuthorizationCode defaultAuthenticationSuccessDecoder Dict.empty



--
-- Json Decoders
--


{-| Json decoder for a positive response. You may provide a custom response decoder using other decoders
from this module, or some of your own craft.

    defaultAuthenticationSuccessDecoder : Decoder AuthenticationSuccess
    defaultAuthenticationSuccessDecoder =
        D.map4 AuthenticationSuccess
            tokenDecoder
            refreshTokenDecoder
            expiresInDecoder
            scopeDecoder

-}
defaultAuthenticationSuccessDecoder : Json.Decoder AuthenticationSuccess
defaultAuthenticationSuccessDecoder =
    Internal.authenticationSuccessDecoder


{-| Json decoder for an errored response.

    case res of
        Err (Http.BadStatus { body }) ->
            case Json.decodeString OAuth.AuthorizationCode.defaultAuthenticationErrorDecoder body of
                Ok { error, errorDescription } ->
                    doSomething

                _ ->
                    parserFailed

        _ ->
            someOtherError

-}
defaultAuthenticationErrorDecoder : Json.Decoder AuthenticationError
defaultAuthenticationErrorDecoder =
    Internal.authenticationErrorDecoder defaultErrorDecoder



--
-- Custom Decoders & Parsers (advanced)
--


{-| Like [`makeAuthorizationUrl`](#makeAuthorizationUrl), but gives you the ability to specify a custom response type
and extra fields to be set on the query.

    makeAuthorizationUrl : Authorization -> Url
    makeAuthorizationUrl =
        makeAuthorizationUrlWith Code Dict.empty

For example, to interact with a service implementing `OpenID+Connect` you may require a different
token type and an extra query parameter as such:

    makeAuthorizationUrlWith
        (CustomResponse "code+id_token")
        (Dict.fromList [ ( "resource", "001" ) ])
        authorization

-}
makeAuthorizationUrlWith : ResponseType -> Dict String String -> Authorization -> Url
makeAuthorizationUrlWith responseType extraFields { clientId, url, redirectUri, scope, state, codeChallenge } =
    let
        extraInternalFields =
            Dict.fromList
                [ ( "code_challenge", codeChallengeToString codeChallenge )
                , ( "code_challenge_method", "S256" )
                ]
    in
    OAuth.AuthorizationCode.makeAuthorizationUrlWith
        responseType
        (Dict.union extraFields extraInternalFields)
        { clientId = clientId
        , url = url
        , redirectUri = redirectUri
        , scope = scope
        , state = state
        }


{-| See [`parseCode`](#parseCode), but gives you the ability to provide your own custom parsers.
-}
parseCodeWith : Parsers error success -> Url -> AuthorizationResultWith error success
parseCodeWith parsers url =
    case OAuth.AuthorizationCode.parseCodeWith parsers url of
        OAuth.AuthorizationCode.Empty ->
            Empty

        OAuth.AuthorizationCode.Success s ->
            Success s

        OAuth.AuthorizationCode.Error e ->
            Error e


{-| Like [`makeTokenRequest`](#makeTokenRequest), but gives you the ability to specify custom grant type and extra
fields to be set on the query.

    makeTokenRequest : (Result Http.Error AuthenticationSuccess -> msg) -> Authentication -> RequestParts msg
    makeTokenRequest =
        makeTokenRequestWith
            AuthorizationCode
            defaultAuthenticationSuccessDecoder
            Dict.empty

-}
makeTokenRequestWith : GrantType -> Json.Decoder success -> Dict String String -> (Result Effect.Http.Error success -> msg) -> Authentication -> RequestParts msg
makeTokenRequestWith grantType decoder extraFields toMsg { credentials, code, codeVerifier, url, redirectUri } =
    let
        extraInternalFields =
            Dict.fromList
                [ ( "code_verifier", codeVerifierToString codeVerifier )
                ]
    in
    OAuth.AuthorizationCode.makeTokenRequestWith
        grantType
        decoder
        (Dict.union extraFields extraInternalFields)
        toMsg
        { credentials = credentials
        , code = code
        , url = url
        , redirectUri = redirectUri
        }


{-| Parsers used in the [`parseCode`](#parseCode) function.

  - `codeParser`: looks for a `code` string
  - `errorParser`: looks for an `error` to build a corresponding `ErrorCode`
  - `authorizationSuccessParser`: selected when the `tokenParser` succeeded to parse the remaining parts
  - `authorizationErrorParser`: selected when the `errorParser` succeeded to parse the remaining parts

-}
type alias Parsers error success =
    { codeParser : Query.Parser (Maybe String)
    , errorParser : Query.Parser (Maybe ErrorCode)
    , authorizationSuccessParser : String -> Query.Parser success
    , authorizationErrorParser : ErrorCode -> Query.Parser error
    }


{-| Default parsers according to RFC-6749.
-}
defaultParsers : Parsers AuthorizationError AuthorizationSuccess
defaultParsers =
    { codeParser = defaultCodeParser
    , errorParser = defaultErrorParser
    , authorizationSuccessParser = defaultAuthorizationSuccessParser
    , authorizationErrorParser = defaultAuthorizationErrorParser
    }


{-| Default `code` parser according to RFC-6749.
-}
defaultCodeParser : Query.Parser (Maybe String)
defaultCodeParser =
    Query.string "code"


{-| Default `error` parser according to RFC-6749.
-}
defaultErrorParser : Query.Parser (Maybe ErrorCode)
defaultErrorParser =
    errorParser errorCodeFromString


{-| Default response success parser according to RFC-6749.
-}
defaultAuthorizationSuccessParser : String -> Query.Parser AuthorizationSuccess
defaultAuthorizationSuccessParser code =
    Query.map (AuthorizationSuccess code)
        stateParser


{-| Default response error parser according to RFC-6749.
-}
defaultAuthorizationErrorParser : ErrorCode -> Query.Parser AuthorizationError
defaultAuthorizationErrorParser =
    authorizationErrorParser


{-| Json decoder for the `expiresIn` field.
-}
defaultExpiresInDecoder : Json.Decoder (Maybe Int)
defaultExpiresInDecoder =
    Internal.expiresInDecoder


{-| Json decoder for the `scope` field (space-separated).
-}
defaultScopeDecoder : Json.Decoder (List String)
defaultScopeDecoder =
    Internal.scopeDecoder


{-| Json decoder for the `scope` (comma- or space-separated).
-}
lenientScopeDecoder : Json.Decoder (List String)
lenientScopeDecoder =
    Internal.lenientScopeDecoder


{-| Json decoder for the `access_token` field.
-}
defaultTokenDecoder : Json.Decoder Token
defaultTokenDecoder =
    Internal.tokenDecoder


{-| Json decoder for the `refresh_token` field.
-}
defaultRefreshTokenDecoder : Json.Decoder (Maybe Token)
defaultRefreshTokenDecoder =
    Internal.refreshTokenDecoder


{-| Json decoder for the `error` field.
-}
defaultErrorDecoder : Json.Decoder ErrorCode
defaultErrorDecoder =
    Internal.errorDecoder errorCodeFromString


{-| Json decoder for the `error_description` field.
-}
defaultErrorDescriptionDecoder : Json.Decoder (Maybe String)
defaultErrorDescriptionDecoder =
    Internal.errorDescriptionDecoder


{-| Json decoder for the `error_uri` field.
-}
defaultErrorUriDecoder : Json.Decoder (Maybe String)
defaultErrorUriDecoder =
    Internal.errorUriDecoder
