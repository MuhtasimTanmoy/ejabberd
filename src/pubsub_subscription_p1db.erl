%%%----------------------------------------------------------------------
%%% File    : pubsub_subscription_p1db.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Handle pubsub subscriptions options with P1DB backend
%%%           based on pubsub_subscription.erl by Brian Cully <bjc@kublai.com>
%%% Created : 15 Apr 2015 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(pubsub_subscription_p1db).

-behaviour(ejabberd_config).

-author("cromain@process-one.net").

%% API
-export([init/3, subscribe_node/3, unsubscribe_node/3,
    get_subscription/3, set_subscription/4,
    make_subid/0,
    get_options_xform/2, parse_options_xform/1]).

-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

-export([add_subscription/3, delete_subscription/3,
	 read_subscription/3, write_subscription/4,
	 mod_opt_type/1, opt_type/1]).

-include("pubsub.hrl").

-include("jlib.hrl").

-define(PUBSUB_DELIVER, <<"pubsub#deliver">>).
-define(PUBSUB_DIGEST, <<"pubsub#digest">>).
-define(PUBSUB_DIGEST_FREQUENCY, <<"pubsub#digest_frequency">>).
-define(PUBSUB_EXPIRE, <<"pubsub#expire">>).
-define(PUBSUB_INCLUDE_BODY, <<"pubsub#include_body">>).
-define(PUBSUB_SHOW_VALUES, <<"pubsub#show-values">>).
-define(PUBSUB_SUBSCRIPTION_TYPE, <<"pubsub#subscription_type">>).
-define(PUBSUB_SUBSCRIPTION_DEPTH, <<"pubsub#subscription_depth">>).
-define(DELIVER_LABEL, <<"Whether an entity wants to receive or disable notifications">>).
-define(DIGEST_LABEL, <<"Whether an entity wants to receive digests "
	"(aggregations) of notifications or all notifications individually">>).
-define(DIGEST_FREQUENCY_LABEL, <<"The minimum number of milliseconds between "
	"sending any two notification digests">>).
-define(EXPIRE_LABEL, <<"The DateTime at which a leased subscription will end or has ended">>).
-define(INCLUDE_BODY_LABEL, <<"Whether an entity wants to receive an "
	"XMPP message body in addition to the payload format">>).
-define(SHOW_VALUES_LABEL, <<"The presence states for which an entity wants to receive notifications">>).
-define(SUBSCRIPTION_TYPE_LABEL, <<"Type of notification to receive">>).
-define(SUBSCRIPTION_DEPTH_LABEL, <<"Depth from subscription for which to receive notifications">>).
-define(SHOW_VALUE_AWAY_LABEL, <<"XMPP Show Value of Away">>).
-define(SHOW_VALUE_CHAT_LABEL, <<"XMPP Show Value of Chat">>).
-define(SHOW_VALUE_DND_LABEL, <<"XMPP Show Value of DND (Do Not Disturb)">>).
-define(SHOW_VALUE_ONLINE_LABEL, <<"Mere Availability in XMPP (No Show Value)">>).
-define(SHOW_VALUE_XA_LABEL, <<"XMPP Show Value of XA (Extended Away)">>).
-define(SUBSCRIPTION_TYPE_VALUE_ITEMS_LABEL, <<"Receive notification of new items only">>).
-define(SUBSCRIPTION_TYPE_VALUE_NODES_LABEL, <<"Receive notification of new nodes only">>).
-define(SUBSCRIPTION_DEPTH_VALUE_ONE_LABEL, <<"Receive notification from direct child nodes only">>).
-define(SUBSCRIPTION_DEPTH_VALUE_ALL_LABEL, <<"Receive notification from all descendent nodes">>).

%%====================================================================
%% API
%%====================================================================
init(_Host, ServerHost, Opts) ->
    Group = gen_mod:get_opt(p1db_group, Opts, fun(G) when is_atom(G) -> G end, 
			ejabberd_config:get_option(
			    {p1db_group, ServerHost}, fun(G) when is_atom(G) -> G end)),
    [Key|Values] = record_info(fields, pubsub_subscription),
    p1db:open_table(pubsub_subscription,
			[{group, Group}, {nosync, true},
			 {schema, [{keys, [Key]},
				   {vals, Values},
				   {enc_key, fun ?MODULE:enc_key/1},
				   {dec_key, fun ?MODULE:dec_key/1},
				   {enc_val, fun ?MODULE:enc_val/2},
				   {dec_val, fun ?MODULE:dec_val/2}]}]),
    ok.

subscribe_node(JID, NodeId, Options) ->
    case catch add_subscription(JID, NodeId, Options)
    of
	{'EXIT', {aborted, Error}} -> Error;
	{error, Error} -> {error, Error};
	Result -> {result, Result}
    end.

unsubscribe_node(JID, NodeId, SubID) ->
    case catch delete_subscription(JID, NodeId, SubID)
    of
	{'EXIT', {aborted, Error}} -> Error;
	{error, Error} -> {error, Error};
	Result -> {result, Result}
    end.

get_subscription(JID, NodeId, SubID) ->
    case catch read_subscription(JID, NodeId, SubID)
    of
	{'EXIT', {aborted, Error}} -> Error;
	{error, Error} -> {error, Error};
	Result -> {result, Result}
    end.

set_subscription(JID, NodeId, SubID, Options) ->
    case catch write_subscription(JID, NodeId, SubID, Options)
    of
	{'EXIT', {aborted, Error}} -> Error;
	{error, Error} -> {error, Error};
	Result -> {result, Result}
    end.


get_options_xform(Lang, Options) ->
    Keys = [deliver, show_values, subscription_type, subscription_depth],
    XFields = [get_option_xfield(Lang, Key, Options) || Key <- Keys],
    {result,
	#xmlel{name = <<"x">>,
	    attrs = [{<<"xmlns">>, ?NS_XDATA}],
	    children =
	    [#xmlel{name = <<"field">>,
		    attrs =
		    [{<<"var">>, <<"FORM_TYPE">>},
			{<<"type">>, <<"hidden">>}],
		    children =
		    [#xmlel{name = <<"value">>, attrs = [],
			    children =
			    [{xmlcdata, ?NS_PUBSUB_SUB_OPTIONS}]}]}]
	    ++ XFields}}.

parse_options_xform(XFields) ->
    case fxml:remove_cdata(XFields) of
	[#xmlel{name = <<"x">>} = XEl] ->
	    case jlib:parse_xdata_submit(XEl) of
		XData when is_list(XData) ->
		    Opts = set_xoption(XData, []),
		    {result, Opts};
		Other -> Other
	    end;
	_ -> {result, []}
    end.

%%====================================================================
%% Internal functions
%%====================================================================
-spec(add_subscription/3 ::
    (
	_JID    :: ljid(),
	_NodeId :: mod_pubsub:nodeIdx(),
	Options :: [] | mod_pubsub:subOptions())
    -> SubId :: mod_pubsub:subId()
    ).

add_subscription(_JID, _NodeId, []) -> make_subid();
add_subscription(_JID, _NodeId, Options) ->
    SubID = make_subid(),
    p1db:insert(pubsub_subscription, SubID, opts_to_p1db(Options)),
    SubID.

-spec(delete_subscription/3 ::
    (
	_JID    :: _,
	_NodeId :: _,
	SubId   :: mod_pubsub:subId())
    -> ok
    ).

delete_subscription(_JID, _NodeId, SubID) ->
    p1db:async_delete(pubsub_subscription, SubID).

-spec(read_subscription/3 ::
    (
	_JID    :: ljid(),
	_NodeId :: _,
	SubID   :: mod_pubsub:subId())
    -> mod_pubsub:pubsubSubscription()
    | {error, notfound}
    ).

read_subscription(_JID, _NodeId, SubID) ->
    case p1db:get(pubsub_subscription, SubID) of
	{ok, BinOpts, _VClock} -> #pubsub_subscription{subid=SubID, options=p1db_to_opts(BinOpts)};
	_ -> {error, notfound}
    end.

-spec(write_subscription/4 ::
    (
	_JID    :: ljid(),
	_NodeId :: _,
	SubID   :: mod_pubsub:subId(),
	Options :: mod_pubsub:subOptions())
    -> ok
    ).

write_subscription(_JID, _NodeId, SubID, Options) ->
    p1db:insert(pubsub_subscription, SubID, opts_to_p1db(Options)).

-spec(make_subid/0 :: () -> SubId::mod_pubsub:subId()).
make_subid() ->
    {T1, T2, T3} = p1_time_compat:timestamp(),
    iolist_to_binary(io_lib:fwrite("~.16B~.16B~.16B", [T1, T2, T3])).

%%
%% Subscription XForm processing.
%%

%% Return processed options, with types converted and so forth, using
%% Opts as defaults.
set_xoption([], Opts) -> Opts;
set_xoption([{Var, Value} | T], Opts) ->
    NewOpts = case var_xfield(Var) of
	{error, _} -> Opts;
	Key ->
	    Val = val_xfield(Key, Value),
	    lists:keystore(Key, 1, Opts, {Key, Val})
    end,
    set_xoption(T, NewOpts).

%% Return the options list's key for an XForm var.
%% Convert Values for option list's Key.
var_xfield(?PUBSUB_DELIVER) -> deliver;
var_xfield(?PUBSUB_DIGEST) -> digest;
var_xfield(?PUBSUB_DIGEST_FREQUENCY) -> digest_frequency;
var_xfield(?PUBSUB_EXPIRE) -> expire;
var_xfield(?PUBSUB_INCLUDE_BODY) -> include_body;
var_xfield(?PUBSUB_SHOW_VALUES) -> show_values;
var_xfield(?PUBSUB_SUBSCRIPTION_TYPE) -> subscription_type;
var_xfield(?PUBSUB_SUBSCRIPTION_DEPTH) -> subscription_depth;
var_xfield(_) -> {error, badarg}.

val_xfield(deliver, [Val]) -> xopt_to_bool(Val);
val_xfield(digest, [Val]) -> xopt_to_bool(Val);
val_xfield(digest_frequency, [Val]) ->
    case catch jlib:binary_to_integer(Val) of
	N when is_integer(N) -> N;
	_ -> {error, ?ERR_NOT_ACCEPTABLE}
    end;
val_xfield(expire, [Val]) -> jlib:datetime_string_to_timestamp(Val);
val_xfield(include_body, [Val]) -> xopt_to_bool(Val);
val_xfield(show_values, Vals) -> Vals;
val_xfield(subscription_type, [<<"items">>]) -> items;
val_xfield(subscription_type, [<<"nodes">>]) -> nodes;
val_xfield(subscription_depth, [<<"all">>]) -> all;
val_xfield(subscription_depth, [Depth]) ->
    case catch jlib:binary_to_integer(Depth) of
	N when is_integer(N) -> N;
	_ -> {error, ?ERR_NOT_ACCEPTABLE}
    end.

%% Convert XForm booleans to Erlang booleans.
xopt_to_bool(<<"0">>) -> false;
xopt_to_bool(<<"1">>) -> true;
xopt_to_bool(<<"false">>) -> false;
xopt_to_bool(<<"true">>) -> true;
xopt_to_bool(_) -> {error, ?ERR_NOT_ACCEPTABLE}.

-spec(get_option_xfield/3 ::
    (
	Lang :: binary(),
	Key  :: atom(),
	Options :: mod_pubsub:subOptions())
    -> xmlel()
    ).

%% Return a field for an XForm for Key, with data filled in, if
%% applicable, from Options.
get_option_xfield(Lang, Key, Options) ->
    Var = xfield_var(Key),
    Label = xfield_label(Key),
    {Type, OptEls} = type_and_options(xfield_type(Key), Lang),
    Vals = case lists:keysearch(Key, 1, Options) of
	{value, {_, Val}} ->
	    [tr_xfield_values(Vals)
		|| Vals <- xfield_val(Key, Val)];
	false -> []
    end,
    #xmlel{name = <<"field">>,
	attrs =
	[{<<"var">>, Var}, {<<"type">>, Type},
	    {<<"label">>, translate:translate(Lang, Label)}],
	children = OptEls ++ Vals}.

type_and_options({Type, Options}, Lang) ->
    {Type, [tr_xfield_options(O, Lang) || O <- Options]};
type_and_options(Type, _Lang) -> {Type, []}.

tr_xfield_options({Value, Label}, Lang) ->
    #xmlel{name = <<"option">>,
	attrs =
	[{<<"label">>, translate:translate(Lang, Label)}],
	children =
	[#xmlel{name = <<"value">>, attrs = [],
		children = [{xmlcdata, Value}]}]}.

tr_xfield_values(Value) ->
    %% Return the XForm variable name for a subscription option key.
    %% Return the XForm variable type for a subscription option key.
    #xmlel{name = <<"value">>, attrs = [],
	children = [{xmlcdata, Value}]}.

xfield_var(deliver) -> ?PUBSUB_DELIVER;
%xfield_var(digest) -> ?PUBSUB_DIGEST;
%xfield_var(digest_frequency) -> ?PUBSUB_DIGEST_FREQUENCY;
%xfield_var(expire) -> ?PUBSUB_EXPIRE;
%xfield_var(include_body) -> ?PUBSUB_INCLUDE_BODY;
xfield_var(show_values) -> ?PUBSUB_SHOW_VALUES;
xfield_var(subscription_type) -> ?PUBSUB_SUBSCRIPTION_TYPE;
xfield_var(subscription_depth) -> ?PUBSUB_SUBSCRIPTION_DEPTH.

xfield_type(deliver) -> <<"boolean">>;
%xfield_type(digest) -> <<"boolean">>;
%xfield_type(digest_frequency) -> <<"text-single">>;
%xfield_type(expire) -> <<"text-single">>;
%xfield_type(include_body) -> <<"boolean">>;
xfield_type(show_values) ->
    {<<"list-multi">>,
	[{<<"away">>, ?SHOW_VALUE_AWAY_LABEL},
	    {<<"chat">>, ?SHOW_VALUE_CHAT_LABEL},
	    {<<"dnd">>, ?SHOW_VALUE_DND_LABEL},
	    {<<"online">>, ?SHOW_VALUE_ONLINE_LABEL},
	    {<<"xa">>, ?SHOW_VALUE_XA_LABEL}]};
xfield_type(subscription_type) ->
    {<<"list-single">>,
	[{<<"items">>, ?SUBSCRIPTION_TYPE_VALUE_ITEMS_LABEL},
	    {<<"nodes">>, ?SUBSCRIPTION_TYPE_VALUE_NODES_LABEL}]};
xfield_type(subscription_depth) ->
    {<<"list-single">>,
	[{<<"1">>, ?SUBSCRIPTION_DEPTH_VALUE_ONE_LABEL},
	    {<<"all">>, ?SUBSCRIPTION_DEPTH_VALUE_ALL_LABEL}]}.

%% Return the XForm variable label for a subscription option key.
xfield_label(deliver) -> ?DELIVER_LABEL;
%xfield_label(digest) -> ?DIGEST_LABEL;
%xfield_label(digest_frequency) -> ?DIGEST_FREQUENCY_LABEL;
%xfield_label(expire) -> ?EXPIRE_LABEL;
%xfield_label(include_body) -> ?INCLUDE_BODY_LABEL;
xfield_label(show_values) -> ?SHOW_VALUES_LABEL;
%% Return the XForm value for a subscription option key.
%% Convert erlang booleans to XForms.
xfield_label(subscription_type) -> ?SUBSCRIPTION_TYPE_LABEL;
xfield_label(subscription_depth) -> ?SUBSCRIPTION_DEPTH_LABEL.

xfield_val(deliver, Val) -> [bool_to_xopt(Val)];
%xfield_val(digest, Val) -> [bool_to_xopt(Val)];
%xfield_val(digest_frequency, Val) ->
%    [iolist_to_binary(integer_to_list(Val))];
%xfield_val(expire, Val) ->
%    [jlib:now_to_utc_string(Val)];
%xfield_val(include_body, Val) -> [bool_to_xopt(Val)];
xfield_val(show_values, Val) -> Val;
xfield_val(subscription_type, items) -> [<<"items">>];
xfield_val(subscription_type, nodes) -> [<<"nodes">>];
xfield_val(subscription_depth, all) -> [<<"all">>];
xfield_val(subscription_depth, N) ->
    [iolist_to_binary(integer_to_list(N))].


bool_to_xopt(true) -> <<"true">>;
bool_to_xopt(false) -> <<"false">>.

%% p1db helpers
opts_to_p1db(Options) when is_list(Options) ->
    term_to_binary({options, Options}).

p1db_to_opts(Bin) when is_binary(Bin) ->
    {options, Opts} = binary_to_term(Bin),
    Opts.

enc_key(SubId) when is_binary(SubId) -> SubId.
dec_key(SubId) when is_binary(SubId) -> SubId.
enc_val(_, [Options]) -> opts_to_p1db(Options).
dec_val(_, Bin) -> [p1db_to_opts(Bin)].

mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(_) -> [p1db_group].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
