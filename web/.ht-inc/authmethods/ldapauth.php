<?php
/*
  Licensed to the Apache Software Foundation (ASF) under one or more
  contributor license agreements.  See the NOTICE file distributed with
  this work for additional information regarding copyright ownership.
  The ASF licenses this file to You under the Apache License, Version 2.0
  (the "License"); you may not use this file except in compliance with
  the License.  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

/**
 * \file
 */

////////////////////////////////////////////////////////////////////////////////
///
/// \fn addLDAPUser($authtype, $userid)
///
/// \param $authtype - index from the $authMechs array
/// \param $userid - a userid without the affiliation part
///
/// \return id from the user table or NULL on failure
///
/// \brief looks up $userid in LDAP according to info in $authMechs array, adds
/// the user to the user table, and returns the new id from the table
///
////////////////////////////////////////////////////////////////////////////////
function addLDAPUser($authtype, $userid) {
	global $authMechs, $mysql_link_vcl;
	$data = getLDAPUserData($authtype, $userid);
	if(is_null($data))
		return NULL;

	$loweruserid = strtolower($userid);

	# check for existance of an expired user if a numericid exists
	if(array_key_exists('numericid', $data)) {
		$query = "SELECT id, "
		       .        "unityid, "
		       .        "affiliationid "
		       . "FROM user "
		       . "WHERE lastupdated < DATE_SUB(NOW(), INTERVAL 1 YEAR) AND "
		       .       "uid = {$data['numericid']} AND "
		       .       "unityid != '$loweruserid'";
		       #.       "affiliationid = {$authMechs[$authtype]['affiliationid']}";
		$qh = doQuery($query, 101);
		if($row = mysql_fetch_assoc($qh)) {
			# find the authtype for this user
			foreach($authMechs as $index => $auth) {
				if($auth['affiliationid'] == $row['affiliationid'] &&
				   $auth['type'] == 'ldap') {
					$checktype = $index;
					break;
				}
			}
			# see if user is still in ldap
			if(! empty($checktype)) {
				$testdata = getLDAPUserData($checktype, $row['unityid']);
				if(! is_null($testdata))
					abort(52);
				# if not, null the uid for the user
				$query = "UPDATE user SET uid = NULL WHERE id = {$row['id']}";
				doQuery($query, 101);
			}
		}
	}

	$query = "INSERT INTO user (";
	if(array_key_exists('numericid', $data))
		$query .=    "uid, ";
	$query .=       "unityid, "
	       .        "affiliationid, "
	       .        "firstname, "
	       .        "lastname, "
	       .        "email, "
	       .        "emailnotices, "
	       .        "lastupdated) "
	       . "VALUES (";
	if(array_key_exists('numericid', $data))
		$query .=    "{$data['numericid']}, ";
	$query .=       "'$loweruserid', "
	       .        "{$authMechs[$authtype]['affiliationid']}, "
	       .        "'{$data['first']}', "
	       .        "'{$data['last']}', "
	       .        "'{$data['email']}', "
	       .        "'{$data['emailnotices']}', "
	       .        "NOW())";
	doQuery($query, 101, 'vcl', 1);
	if(mysql_affected_rows($mysql_link_vcl)) {
		$qh = doQuery("SELECT LAST_INSERT_ID() FROM user", 101);
		if(! $row = mysql_fetch_row($qh)) {
			abort(101);
		}
		return $row[0];
	}
	return NULL;
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn validateLDAPUser($type, $loginid)
///
/// \param $type - an array from the $authMechs table
/// \param $loginid - a userid without the affiliation part
///
/// \return 1 if user was found in ldap, 0 if not
///
/// \brief checks to see if a user is in ldap
///
////////////////////////////////////////////////////////////////////////////////
function validateLDAPUser($type, $loginid) {
	global $authMechs;
	$auth = $authMechs[$type];
	$ds = ldap_connect("ldaps://{$auth['server']}/");
	if(! $ds)
		return -1;
	ldap_set_option($ds, LDAP_OPT_PROTOCOL_VERSION, 3);
	ldap_set_option($ds, LDAP_OPT_REFERRALS, 0);

	if(array_key_exists('masterlogin', $auth) && strlen($auth['masterlogin']))
		$res = ldap_bind($ds, $auth['masterlogin'], $auth['masterpwd']);
	else 
		$res = ldap_bind($ds);

	if(! $res)
		return -1;

	$return = array($auth['email']);

	$search = ldap_search($ds,
	                      $auth['binddn'], 
	                      "{$auth['unityid']}=$loginid",
	                      $return, 0, 3, 15);
	if(! $search)
		return -1;

	$data = ldap_get_entries($ds, $search);
	if($data['count'])
		return 1;

	return 0;
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn updateLDAPUser($authtype, $userid)
///
/// \param $authtype - an array from the $authMechs table
/// \param $userid - a userid without the affiliation part
///
/// \return an array of user information or NULL on error
///
/// \brief pulls the user's information from ldap, updates it in the db, and 
/// returns an array of the information
///
////////////////////////////////////////////////////////////////////////////////
function updateLDAPUser($authtype, $userid) {
	global $authMechs;
	$userData = getLDAPUserData($authtype, $userid);
	if(is_null($userData))
		return NULL;
	$affilid = $authMechs[$authtype]['affiliationid'];
	$now = unixToDatetime(time());

	// select desired data from db
	$query = "SELECT i.name AS IMtype, "
	       .        "u.IMid AS IMid, "
	       .        "u.affiliationid, "
	       .        "af.name AS affiliation, "
	       .        "af.shibonly, "
	       .        "u.emailnotices, "
	       .        "a.name AS adminlevel, "
	       .        "a.id AS adminlevelid, "
	       .        "u.preferredname AS preferredname, "
	       .        "u.uid AS uid, "
	       .        "u.id AS id, "
	       .        "u.width AS width, "
	       .        "u.height AS height, "
	       .        "u.bpp AS bpp, "
	       .        "u.audiomode AS audiomode, "
	       .        "u.mapdrives AS mapdrives, "
	       .        "u.mapprinters AS mapprinters, "
	       .        "u.mapserial AS mapserial, "
	       .        "u.showallgroups "
	       . "FROM user u, "
	       .      "IMtype i, "
	       .      "adminlevel a, "
	       .      "affiliation af "
	       . "WHERE u.IMtypeid = i.id AND "
	       .       "u.adminlevelid = a.id AND "
	       .       "af.id = $affilid AND ";
	if(array_key_exists('numericid', $userData))
		$query .=   "u.uid = " . $userData["numericid"];
	else {
		$query .=   "u.unityid = '$userid' AND "
		       .    "u.affiliationid = $affilid";
	}
	$qh = doQuery($query, 255);
	// if get a row
	//    update db
	//    update results from select
	if($user = mysql_fetch_assoc($qh)) {
		$user["unityid"] = $userid;
		$user["firstname"] = $userData['first'];
		$user["lastname"] = $userData["last"];
		$user["email"] = $userData["email"];
		$user["lastupdated"] = $now;
		$query = "UPDATE user "
		       . "SET unityid = '$userid', "
		       .     "firstname = '{$userData['first']}', "
		       .     "lastname = '{$userData['last']}', "
		       .     "email = '{$userData['email']}', "
		       .     "lastupdated = '$now' ";
		if(array_key_exists('numericid', $userData))
			$query .= "WHERE uid = " . $userData["numericid"];
		else
			$query .= "WHERE unityid = '$userid' AND "
			       .        "affiliationid = $affilid";
		doQuery($query, 256, 'vcl', 1);
	}
	else {
	//    call addLDAPUser
		$id = addLDAPUser($authtype, $userid);
		$query = "SELECT u.unityid AS unityid, "
		       .        "u.affiliationid, "
		       .        "af.name AS affiliation, "
		       .        "u.firstname AS firstname, "
		       .        "u.lastname AS lastname, "
		       .        "u.preferredname AS preferredname, "
		       .        "u.email AS email, "
		       .        "i.name AS IMtype, "
		       .        "u.IMid AS IMid, "
		       .        "u.uid AS uid, "
		       .        "u.id AS id, "
		       .        "a.name AS adminlevel, "
		       .        "a.id AS adminlevelid, "
		       .        "u.width AS width, "
		       .        "u.height AS height, "
		       .        "u.bpp AS bpp, "
		       .        "u.audiomode AS audiomode, "
		       .        "u.mapdrives AS mapdrives, "
		       .        "u.mapprinters AS mapprinters, "
		       .        "u.mapserial AS mapserial, "
		       .        "u.showallgroups, "
		       .        "u.lastupdated AS lastupdated "
		       . "FROM user u, "
		       .      "IMtype i, "
		       .      "affiliation af, "
		       .      "adminlevel a "
		       . "WHERE u.IMtypeid = i.id AND "
		       .       "u.adminlevelid = a.id AND "
		       .       "u.affiliationid = af.id AND "
		       .       "u.id = $id";
		$qh = doQuery($query, 101);
		if(! $user = mysql_fetch_assoc($qh))
			return NULL;
	}

	// TODO handle generic updating of groups
	switch(getAffiliationName($affilid)) {
		case 'EXAMPLE1':
			updateEXAMPLE1Groups($user);
			break;
		case 'EXAMPLE2':
			updateEXAMPLE2Groups($user);
			break;
		default:
			//TODO possibly add to a default group
	}
	$user["groups"] = getUsersGroups($user["id"], 1);
	$user["privileges"] = getOverallUserPrivs($user["id"]);
	$user['login'] = $user['unityid'];
	return $user;
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn getLDAPUserData($authtype, $userid)
///
/// \param $authtype - an array from the $authMechs table
/// \param $userid - a userid without the affiliation part
///
/// \return an array of user information
///
/// \brief gets user information from ldap
///
////////////////////////////////////////////////////////////////////////////////
function getLDAPUserData($authtype, $userid) {
	global $authMechs, $mysql_link_vcl;
	$auth = $authMechs[$authtype];
	$donumericid = 0;
	if(array_key_exists('numericid', $auth))
		$donumericid = 1;

	$ds = ldap_connect("ldaps://{$auth['server']}/");
	// FIXME
	ldap_set_option($ds, LDAP_OPT_PROTOCOL_VERSION, 3);
	ldap_set_option($ds, LDAP_OPT_REFERRALS, 0);

	if(array_key_exists('masterlogin', $auth) && strlen($auth['masterlogin']))
		$res = ldap_bind($ds, $auth['masterlogin'], $auth['masterpwd']);
	else 
		$res = ldap_bind($ds);

	// FIXME

	$ldapsearch = array($auth['firstname'],
	                    $auth['lastname'],
	                    $auth['email']);
	if($donumericid)
		array_push($ldapsearch, $auth['numericid']);
	# FIXME hack
	array_push($ldapsearch, 'gecos');

	$search = ldap_search($ds,
	                      $auth['binddn'], 
	                      "{$auth['unityid']}=$userid",
	                      $ldapsearch, 0, 3, 15);
	$return = array();
	if($search) {
		$tmpdata = ldap_get_entries($ds, $search);
		if(! $tmpdata['count'])
			return NULL;
		$data = array();
		for($i = 0; $i < $tmpdata['count']; $i++) {
			for($j = 0; $j < $tmpdata[$i]['count']; $j++) {
				if(is_array($tmpdata[$i][$tmpdata[$i][$j]]))
					$data[strtolower($tmpdata[$i][$j])] = $tmpdata[$i][$tmpdata[$i][$j]][0];
				else
					$data[strtolower($tmpdata[$i][$j])] = $tmpdata[$i][$tmpdata[$i][$j]];
			}
		}
		// FIXME hack to take care of users that don't have full info in ldap
		if(! array_key_exists($auth['firstname'], $data) &&
		   ! array_key_exists(strtolower($auth['firstname']), $data)) {
			if(array_key_exists('gecos', $data)) {
				$tmpArr = explode(' ', $data['gecos']);
				if(count($tmpArr) == 3) {
					$data[strtolower($auth['firstname'])] = $tmpArr[0];
					$data[strtolower($auth['lastname'])] = $tmpArr[2];
				}
				elseif(count($tmpArr) == 2) {
					$data[strtolower($auth['firstname'])] = $tmpArr[0];
					$data[strtolower($auth['lastname'])] = $tmpArr[1];
				}
				elseif(count($tmpArr) == 1) {
					$data[strtolower($auth['firstname'])] = '';
					$data[strtolower($auth['lastname'])] = $tmpArr[0];
				}
			}
			else {
				$data[strtolower($auth['firstname'])] = '';
				$data[strtolower($auth['lastname'])] = '';
			}
		}
		if(! array_key_exists($auth['email'], $data)) {
			$data[strtolower($auth['email'])] = $userid . $auth['defaultemail'];
		}

		$return['first'] = ereg_replace("'", "\'", $data[strtolower($auth['firstname'])]);
		$return['last'] = ereg_replace("'", "\'", $data[strtolower($auth['lastname'])]);
		if($donumericid)
			$return['numericid'] = $data[strtolower($auth['numericid'])];
		$return['email'] = $data[strtolower($auth['email'])];
		$return['emailnotices'] = 1;

		return $return;
	}
	return NULL;
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn updateEXAMPLE1Groups($user)
///
/// \param $user - an array of user data
///
/// \brief builds an array of nisNetgroups user is a member of and calls
/// updateGroups
///
////////////////////////////////////////////////////////////////////////////////
function updateEXAMPLE1Groups($user) {
	$count = 0;
	do {
		if($count > 2)
			abort(35);
		if($count > 0)
			sleep(1);
		ldapUIDLookup($user['unityid'], $userData);
		$count++;
	} while(! array_key_exists("info", $userData) ||
		! array_key_exists("account", $userData["info"]) ||
		! array_key_exists("memberNisNetgroup", $userData["info"]["account"]));
	$newusergroups = array();
	if(! array_key_exists('info', $userData) ||
	   ! array_key_exists('account', $userData['info']) ||
	   ! array_key_exists('memberNisNetgroup', $userData['info']['account']))
		return;
	foreach($userData["info"]["account"]["memberNisNetgroup"] as $item) {
		$tmpArr = explode(',', $item);
		$tmpArr = explode('=', $tmpArr[0]);
		if(! array_key_exists(1, $tmpArr)) {
			continue;
		}
		$grp = mysql_escape_string($tmpArr[1]);
		array_push($newusergroups, getUserGroupID($grp, $user['affiliationid']));
	}
	$newusergroups = array_unique($newusergroups);
	updateGroups($newusergroups, $user["id"]);
}

////////////////////////////////////////////////////////////////////////////////
///
/// \fn updateEXAMPLE2Groups($user)
///
/// \param $user - an array of user data
///
/// \brief builds an array of memberof groups user is a member of and calls
/// updateGroups
///
////////////////////////////////////////////////////////////////////////////////
function updateEXAMPLE2Groups($user) {
	global $authMechs;
	$auth = $authMechs['EXAMPLE2 LDAP'];
	$ds = ldap_connect("ldaps://{$auth['server']}/");
	if(! $ds)
		return 0;
	ldap_set_option($ds, LDAP_OPT_PROTOCOL_VERSION, 3);
	ldap_set_option($ds, LDAP_OPT_REFERRALS, 0);

	$res = ldap_bind($ds, $auth['masterlogin'],
	                  $auth['masterpwd']);
	if(! $res)
		return 0;

	$search = ldap_search($ds,
	                      $auth['binddn'], 
	                      "{$auth['unityid']}={$user['unityid']}",
	                      array('memberof'), 0, 10, 15);
	if(! $search)
		return 0;

	$data = ldap_get_entries($ds, $search);
	$newusergroups = array();
	if(! array_key_exists('memberof', $data[0]))
		return;
	for($i = 0; $i < $data[0]['memberof']['count']; $i++) {
		if(preg_match('/^CN=(.+),OU=CourseRolls,DC=example2,DC=com/', $data[0]['memberof'][$i], $match) ||
		   preg_match('/^CN=(Students_Enrolled),OU=Students,DC=example2,DC=com$/', $data[0]['memberof'][$i], $match) ||
		   preg_match('/^CN=(Staff),OU=IT,DC=example2,DC=com$/', $data[0]['memberof'][$i], $match))
			array_push($newusergroups, getUserGroupID($match[1], $user['affiliationid']));
	}
	$newusergroups = array_unique($newusergroups);
	updateGroups($newusergroups, $user["id"]);
}
