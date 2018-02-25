%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Steven Danna <steve@chef.io>
%% @copyright 2015 Chef Software, Inc.
%%
%% The global_admins_user_addition addition callback adds the user
%% group from a given organization into the ORGNAME_global_admins
%% group for that organization.
%%
%% The ORGNAME_global_admins group has a signle purpose: providing
%% READ access to other user objects in ORGNAME.  Thus, the only
%% change that this migration produces is that users that share an org
%% can now see each others user objects.
%%
%% This change is necessary to facilitate the use of chef-vault.
%%
-module(mover_global_admins_user_addition_callback).

-export([
         migration_init/0,
         migration_complete/0,
         migration_type/0,
         supervisor/0,
         migration_start_worker_args/2,
         migration_action/2,
         next_object/0,
         error_halts_migration/0,
         reconfigure_object/2,
         needs_account_dets/0
        ]).

-include("mover.hrl").

-record(org, {name, id, authz_id}).
-record(group, {name, id, authz_id}).

migration_init() ->
    mv_oc_chef_authz_http:create_pool(),
    mover_transient_migration_queue:initialize_queue(?MODULE, all_orgs()).

migration_action(#org{name = OrgName} = Org, _) ->
    GAGroup = global_admin_group(Org),
    UserGroup = user_group(Org),
    case add_group_to_group(UserGroup, GAGroup) of
        ok ->
            ok;
        %% Non-fatal errors.
        %% We ignore the following error cases
        %%
        %% - no users group
        %% - no global_admins groups
        %% - missing bifrost data
        %%
        %% Orgs in this state cannot be migrated and would need futher repair. We ignore
        %% these errors to ensure that the partybus migration does not fail since this is a
        %% policy-change migration not required for correct operation of chef-client runs.
        {error, no_global_admins_group} ->
            lager:info("Organization ~p has no global_admins group and cannot be migrated", [OrgName]),
            ok;
        {error, no_user_group} ->
            lager:info("Organization ~p has no user group and cannot be migrated.", [OrgName]),
            ok;
        {error, not_found} ->
            lager:info("Organization ~p is missing bifrost data for either the users or global_admins group and cannot be migrated.", [OrgName]),
            ok;
        {error, Error} ->
            lager:error("Organization ~p failed during group addition.", [OrgName]),
            Error
    end.

migration_complete() ->
    mv_oc_chef_authz_http:delete_pool().

global_admin_query() ->
    <<"SELECT name, id, authz_id FROM groups WHERE name = $1">>.

users_group_query() ->
    <<"SELECT name, id, authz_id FROM groups WHERE name = 'users' AND org_id = $1">>.

all_orgs_query() ->
    <<"SELECT name, id, authz_id FROM orgs">>.

all_orgs() ->
    %% TODO: Will this be Bad(TM) in Hosted?
    {ok, Orgs} = sqerl:select(all_orgs_query(), [], rows_as_records, [org, record_info(fields, org)]),
    Orgs.

global_admin_group(Org) ->
    case sqerl:select(global_admin_query(), [ga_groupname(Org)], rows_as_records, [group, record_info(fields, group)]) of
        {ok, [Group]} ->
            Group;
        {ok, none} ->
            {error, no_global_admins_group}
    end.

ga_groupname(#org{name = OrgName}) ->
    iolist_to_binary([OrgName, <<"_global_admins">>]).

user_group(#org{id = OrgId}) ->
    case sqerl:select(users_group_query(), [OrgId], rows_as_records, [group, record_info(fields, group)]) of
        {ok, [Group]} ->
            Group;
        {ok, none} ->
            {error, no_user_group}
    end.

add_group_to_group({error, no_user_group} = Error, _GAGroup) ->
    Error;
add_group_to_group(_UserGroup, {error, no_global_admins_group} = Error) ->
    Error;
add_group_to_group(#group{authz_id = IdToAdd}, #group{authz_id = TargetId}) ->
    mv_oc_chef_authz:add_to_group(TargetId, group, IdToAdd, superuser).

%%
%% Generic mover callback functions for
%% a transient queue migration
%%
needs_account_dets() ->
    false.

migration_start_worker_args(Object, AcctInfo) ->
    [Object, AcctInfo].

next_object() ->
    mover_transient_migration_queue:next(?MODULE).

migration_type() ->
    <<"global_admins_user_addition">>.

supervisor() ->
    mover_transient_worker_sup.

error_halts_migration() ->
    false.

reconfigure_object(_ObjectId, _AcctInfo) ->
    ok.
