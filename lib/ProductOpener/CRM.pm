# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2023 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

ProductOpener::CRM - manages integration with the Odoo CRM

=head1 SYNOPSIS

C<ProductOpener::CRM> contains functions to interact with the Odoo CRM


=head1 DESCRIPTION

For clarity:
	- user/org refers to the pro platform side
	- contact/company refers to the CRM side, where:
			contact => Odoo partner is an 'individual'
	  		company => Odoo partner is a 'company'

	- tags => crm.tag
	- category => res.partner.category

Requirements before enabling CRM sync:
	- check required_tag_labels and required_category_labels

=cut

package ProductOpener::CRM;

use ProductOpener::PerlStandards;
use Exporter qw< import >;

BEGIN {
	use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);
	@EXPORT_OK = qw(
		&init_crm_data
		&find_or_create_contact
		&find_or_create_company
		&add_contact_to_company
		&create_onboarding_opportunity
		&add_user_to_company
		&remove_user_from_company
		&change_company_main_contact
		&update_last_import_date
		&update_last_export_date
	);
	%EXPORT_TAGS = (all => [@EXPORT_OK]);

}
use vars @EXPORT_OK;

use ProductOpener::Config2;
use ProductOpener::Tags qw/%country_codes_reverse/;
use ProductOpener::Users qw/retrieve_user store_user/;
use ProductOpener::Orgs qw/retrieve_org is_user_in_org_group/;
use ProductOpener::Paths qw/%BASE_DIRS ensure_dir_created/;
use ProductOpener::Store qw/retrieve store/;
use XML::RPC;
use Log::Any qw($log);

my $crm_data;
# Tags (crm.tag) must be defined in Odoo: CRM > Configuration > Tags
my @required_tag_labels = qw(onboarding);
# Category (res.partner.category) must be defined in Odoo :
# Contact > contact (individual or company) form > Tags field > "Search More"
my @required_category_labels = qw(Producer);

# special commands to manipulate Odoo relation One2Many and Many2Many
# see https://www.odoo.com/documentation/15.0/developer/reference/backend/orm.html#odoo.fields.Command
my %commands = (create => 0, update => 1, delete => 2, unlink => 3, link => 4, clear => 5, set => 6);

our @api_credentials;
our $xmlrpc;

=head2 find_or_create_contact ($user_ref)

Attempts to find a contact, and if it doesn't exist, creates it

=head3 Arguments

=head4 $user_ref 

the user to which a 'contact' in the CRM should be linked

=head3 Return values

the id of the contact, or undef if an error occur

=cut

sub find_or_create_contact($user_ref) {
	my $contact_id = find_contact($user_ref);
	if (defined $contact_id) {
		return if not link_user_with_contact($user_ref, $contact_id);
	}
	else {
		$contact_id = create_contact($user_ref);
	}
	return $contact_id;
}

=head2 link_user_with_contact ($org_ref, $contact_id = undef)

Set the off_username field of a contact to the user_id  

=head3 Arguments

=head4 $user_ref 

=head4 $contact_id 

=head3 Return values

1 if success, undef otherwise

=cut

sub link_user_with_contact($user_ref, $contact_id) {
	my $req = make_odoo_request(
		'res.partner',
		'write',
		[
			[$contact_id],
			{x_off_username => $user_ref->{userid}, category_id => [[$commands{link}, $crm_data->{tags}{Producer}]]}
		]
	);
	$log->debug("link_user_with_contact", {user_id => $user_ref->{userid}, res => $req}) if $log->is_debug();
	return $req;
}

=head2 find_contact ($user_ref)

Finds a contact that has the user_id or same email as the given user_ref

=head3 Arguments

=head4 $user_ref

=head3 Return values

the contact id or undef

=cut

sub find_contact($user_ref) {
	# find the contact with the same user_id OR email, by date of creation (oldest first)
	my $req = make_odoo_request(
		'res.partner',
		'search_read',
		[
			[
				['is_company', '=', 0],
				'|',
				['x_off_username', '=', $user_ref->{userid}],
				['email', '=', $user_ref->{email}]
			]
		],
		{fields => ['name', 'id', 'parent_id'], order => 'create_date ASC', limit => 1}
	);
	return if not defined $req;
	my $contact = $req->[0];
	$log->debug("find_matching_contact", {contact => $contact}) if $log->is_debug();
	return if not defined $contact;
	return $contact->{id};
}

=head2 create_contact ($user_ref)

Creates a new contact in Odoo from a user

=head3 Arguments

=head4 $org_ref

=head3 Return values

the id of the created contact

=cut

sub create_contact ($user_ref) {

	$log->debug("create_contact", {crm_data => $crm_data}) if $log->is_debug();

	my $contact = {
		name => $user_ref->{name},
		x_off_username => $user_ref->{userid},
		email => $user_ref->{email},
		phone => $user_ref->{phone},
		category_id => [$crm_data->{tags}{Producer}],
	};

	# find country code id in Odoo
	my $user_country_code = uc($country_codes_reverse{$user_ref->{country}}) || 'EN';
	my $country_id = make_odoo_request(
		'res.country', 'search_read',
		[[['code', '=', $user_country_code]]],
		{fields => ['code', 'id']}
	);
	$contact->{country_id} = $country_id->[0]{id};

	# find spoken language's code in Odoo
	# 'lang' are actived languages in Odoo
	my $Odoo_lang = make_odoo_request(
		'res.lang', 'search_read',
		[[['iso_code', '=', $user_ref->{preferred_language}]]],
		{fields => ['code']}
	);
	my $found_lang = $Odoo_lang->[0];
	$contact->{lang} = $found_lang->{code} // 'en_US';    # default to english
	if (defined $found_lang->{id}) {
		$contact->{x_off_languages} = [$found_lang->{id}];
	}

	# create new contact with linked organization
	my $contact_id = make_odoo_request('res.partner', 'create', [{%$contact}]);
	$log->debug("create_contact", {contact_id => $contact_id}) if $log->is_debug();
	return $contact_id;
}

=head2 find_or_create_company ($org_ref, $contact_id = undef)

Attempts to find a company, and if it doesn't exist, creates it

=head3 Arguments

=head4 $org_ref 

the organization to which a 'company' in the CRM should be linked

=head4 $contact_id 

Helps the strategy to find the company

=head3 Return values

The id of the contact, or undef if an error occurred

=cut

sub find_or_create_company($org_ref, $contact_id = undef) {
	my $company_id = find_company($org_ref, $contact_id);
	if (defined $company_id) {
		return if not link_org_with_company($org_ref, $company_id);
	}
	else {
		$company_id = create_company($org_ref);
	}
	return $company_id;
}

=head2 link_org_with_company ($org_ref, $company_id)

Set the off_org field of a contact to the org_id  

=head3 Arguments

=head4 $org_ref

=head4 $company_id

=head3 Return values

1 if success, undef otherwise

=cut

sub link_org_with_company($org_ref, $company_id) {
	my $user_ref = retrieve_user($org_ref->{main_contact});
	my $req = make_odoo_request(
		'res.partner',
		'write',
		[
			[$company_id],
			{
				x_off_org_id => $org_ref->{org_id},
				category_id => [[$commands{link}, $crm_data->{tags}{Producer}]],
				x_off_main_contact => $user_ref->{crm_user_id}
			}
		]
	);
	return $req;
}

=head2 find_company ($name)

Finds the oldest company following this strategy:

1. if the company has the corresponding off_org_id, use this one
2. if the contact_id is defined and the company he belongs to has no off_org_id, use this one 
3. if there is a company with the exact same name, use this one

=head3 Arguments

=head4 $user_ref

=head4 $org_ref

=head3 Return values

the company if found, undef otherwise

=cut

sub find_company($org_ref, $contact_id = undef) {
	# escape % and _ in org name, because of the ilike operator
	my $org_name =~ s/([%_])/\\$1/g;
	# 1. & 3. merged in one query
	my $companies = make_odoo_request(
		'res.partner',
		'search_read',
		[
			[
				'&', ['is_company', '=', 1],
				'|', ['x_off_org_id', '=', $org_ref->{org_id}],
				'&',
				['name', '=ilike', $org_name],
				['x_off_org_id', 'like', '0']
			]
		],
		{fields => ['name', 'id', 'x_off_org_id', 'is_company'], order => 'create_date ASC'}
	);
	return if not defined $companies;
	my $company = $companies->[0];
	# 1.
	if (    defined $contact_id
		and defined $company->{id}
		and $company->{x_off_org_id} ne $org_ref->{org_id})
	{
		# find the company of the contact
		my $req = make_odoo_request('res.partner', 'read', [$contact_id], {fields => ['name', 'id', 'parent_id']});
		return if not defined $req;
		# check if the company has no off_org_id
		my $contact = $req->[0];

		if (defined $contact && $contact->{parent_id} ne '0') {
			my $req = make_odoo_request(
				'res.partner', 'read',
				[$company->{parent_id}->[0]],
				{fields => ['name', 'id', 'x_off_org_id']}
			);
			my $contact_company = $req->[0];
			if (defined $contact_company and $company->{x_off_org_id} eq '0') {
				# 2.
				return $contact_company->{id};
			}
		}
		# 3
	}
	return $company->{id};
}

=head2 create_company ($org_ref)

Creates a new company in Odoo from an org

=head3 Arguments

=head4 $org_ref

=head3 Return values

the id of the created company

=cut

sub create_company ($org_ref) {
	my $main_contact_user_ref = retrieve_user($org_ref->{main_contact});
	my $company = {
		name => $org_ref->{name},
		phone => $org_ref->{phone},
		email => $org_ref->{email},
		website => $org_ref->{website},
		category_id => [$crm_data->{tags}{Producer}],    # "Producer" category id in Odoo
		is_company => 1,
		x_off_org_id => $org_ref->{org_id},
		x_off_main_contact => $main_contact_user_ref->{crm_user_id},
	};
	my $company_id = make_odoo_request('res.partner', 'create', [{%$company}]);
	$log->debug("create_company", {company_id => $company_id, company => $company}) if $log->is_debug();
	return $company_id;
}

=head2 add_contact_to_company ($org_ref)

Add a contact to a company in Odoo

=head3 Arguments

=head4 $contact_id

=head4 $company_id

=head3 Return values

1 if success, undef otherwise

=cut

sub add_contact_to_company($contact_id, $company_id) {
	# set contact in children of company
	make_odoo_request('res.partner', 'write', [[$company_id], {child_ids => [[$commands{link}, $contact_id]]}]);
	# set company of the contact
	my $result = make_odoo_request('res.partner', 'write', [[$contact_id], {parent_id => $company_id}]);
	$log->debug("add_contact_to_company", {company_id => $company_id, contact_id => $contact_id}) if $log->is_debug();
	return $result;
}

=head2 create_onboarding_opportunity ($name, $company_id, $contact_id)

create an opportunity attached to a 

=head3 Arguments

=head4 $name

The name of the opportunity

=head4 $partner_id

The id of the partner to attach the opportunity to.
It can be a contact or a company

=head3 Return values

the id of the created opportunity

=cut

sub create_onboarding_opportunity ($name, $company_id, $contact_id) {
	my $opportunity_id = make_odoo_request('crm.lead', 'create',
		[{name => $name, partner_id => $contact_id, tag_ids => [[$commands{link}, $crm_data->{tags}{onboarding}]]}]);
	$log->debug("create_opportunity", {opportunity_id => $opportunity_id}) if $log->is_debug();
	return $opportunity_id;
}

=head2 add_user_to_company ($user_id, $company_id)

Add a user to a company in Odoo.
Attempts to find the contact, create it if it doesn't exist, and add it to the company.

side effect: update user_ref with the corresponding CRM contact_id

=head3 Arguments

=head4 $user_id

=head4 $company_id

=head3 Return values

the contact_id, undef if an error occurred while getting the contact_id

=cut

sub add_user_to_company($user_id, $company_id) {
	my $user_ref = retrieve_user($user_id);
	my $contact_id = find_contact($user_ref);
	if (not defined $contact_id) {
		$contact_id = create_contact($user_ref);
	}
	elsif (not link_user_with_contact($user_ref, $contact_id)) {
		return;
	}
	add_contact_to_company($contact_id, $company_id);
	$user_ref->{crm_user_id} = $contact_id;
	store_user($user_ref);
	return $contact_id;
}

sub remove_user_from_company($user_id, $company_id) {
	my $user_ref = retrieve_user($user_id);
	my $req = make_odoo_request('res.partner', 'write',
		[[$company_id], {child_ids => [[$commands{unlink}, $user_ref->{crm_user_id}]]}]);
	my $result = make_odoo_request('res.partner', 'write', [[$user_ref->{crm_user_id}], {parent_id => 0}]);
	return $req;
}

=head2 change_company_main_contact ($org_ref, $user_id)

Change the main contact of a company, 
based on the associated company and contact in the CRM of the given org and user.
Will also update the main contact of the opportunity associated with the org.

=head3 Arguments

=head4 $org_ref

=head4 $user_id 

id of a member of the organization

=head3 Return values

1 if success, undef otherwise

=cut

sub change_company_main_contact($org_ref, $user_id) {

	if (not is_user_in_org_group($org_ref, $user_id, 'members')) {
		$log->error("change_company_main_contact",
			{cause => "$user_id is not in the organization `$org_ref->{org_id}`"})
			if $log->is_error();
		return;
	}

	my $user_ref = retrieve_user($user_id);

	my $req_opportunity
		= make_odoo_request('crm.lead', 'write',
		[[$org_ref->{crm_opportunity_id}], {partner_id => $user_ref->{crm_user_id}}]);

	my $req_company
		= make_odoo_request('res.partner', 'write',
		[[$org_ref->{crm_org_id}], {x_off_main_contact => $user_ref->{crm_user_id}}]);
	return if not $req_company;

	$log->debug("change_company_main_contact", {org_id => $org_ref->{org_id}, userid => $user_id}) if $log->is_debug();
	return $req_company;
}

sub update_last_import_date($org_id, $time) {
	return update_company_last_action_date($org_id, $time, 'x_off_last_import_date');
}

sub update_last_export_date($org_id, $time) {
	return update_company_last_action_date($org_id, $time, 'x_off_last_export_date');
}

sub update_company_last_action_date($org_id, $time, $field) {
	my $org_ref = retrieve_org($org_id);
	if (not defined $org_ref->{crm_org_id}) {
		return;
	}
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime($time);
	$year += 1900;
	$mon += 1;
	my $date_string = sprintf("%04d-%02d-%02d", $year, $mon, $mday);
	$log->debug("update_last_company_action_date", {org_id => $org_id, date => $date_string, field => $field})
		if $log->is_debug();
	return make_odoo_request('res.partner', 'write', [[$org_ref->{crm_org_id}], {$field => $date_string}]);
}

=head2 make_odoo_request (@params)

Calls Odoo's API with the given parameters

=head3 Return values

the response or undef if an error occurred

=cut

sub make_odoo_request(@params) {
	if (not defined $ProductOpener::Config2::crm_api_url) {
		# Odoo CRM is not configured
		return;
	}
	if (not defined $xmlrpc) {
		# Initialize the connection
		my $api_url = $ProductOpener::Config2::crm_api_url;
		my $username = $ProductOpener::Config2::crm_username;
		my $db = $ProductOpener::Config2::crm_db;
		my $pwd = $ProductOpener::Config2::crm_pwd;

		eval {$xmlrpc = XML::RPC->new($api_url . 'common');};
		if ($@) {
			$log->error("Odoo", {error => $@, reason => "Could not connect to Odoo CRM"}) if $log->is_error();
			$xmlrpc = undef;
			return;
		}

		my $uid;
		eval {$uid = $xmlrpc->call('authenticate', $db, $username, $pwd, {});};
		if ($@) {
			$log->error("Odoo", {error => $@, reason => "Could not authenticate to Odoo CRM"}) if $log->is_error();
			$xmlrpc = undef;
			return;
		}
		@api_credentials = ($db, $uid, $pwd);
		$xmlrpc = XML::RPC->new($api_url . 'object');
	}

	my $result;
	eval {$result = $xmlrpc->call('execute_kw', (@api_credentials, @params));};
	if ($@) {
		$log->error("Odoo", {error => $@, params => \@params, reason => "Could not call Odoo"}) if $log->is_error();
		$xmlrpc = undef;
		return;
	}

	# Check if the result is an error
	if (ref($result) eq 'HASH' && exists $result->{faultCode}) {
		$log->error("Odoo",
			{error => $result->{faultString}, params => \@params, reason => "Odoo call returned an error"})
			if $log->is_error();
		return;
	}

	return $result;
}

=head2 init_crm_data()

Initialize the CRM data from Odoo.
It is called by lib/startup_apache.pl startup script

=head4 die if some taxonomies cannot be loaded $die_if_some_taxonomies_cannot_be_loaded

# Die if CRM env vars are set and required data cannot be loaded from cache or fetched from CRM

=cut

sub init_crm_data() {
	if (not defined $ProductOpener::Config2::crm_api_url) {
		# Odoo CRM is not configured
		return;
	}

	ensure_dir_created($BASE_DIRS{CACHE_TMP});

	$crm_data = retrieve("$BASE_DIRS{CACHE_TMP}/crm_data.sto");

	my $tmp_crm_data = {};
	eval {
		# Tag
		my $tags
			= make_odoo_request('crm.tag', 'search_read', [[]], {fields => ['name', 'id'], order => 'create_date ASC'});
		defined $tags or die "CRM did not return tags";

		my %odoo_tag_id;
		foreach my $tag (@$tags) {
			$odoo_tag_id{$tag->{name}} = $tag->{id};
		}

		foreach my $tag_label (@required_tag_labels) {
			if (not exists $odoo_tag_id{$tag_label}) {
				die "Tag `$tag_label` not found in CRM";
			}
			$tmp_crm_data->{tags}{$tag_label} = $odoo_tag_id{$tag_label};
		}

		# Category
		my $categories = make_odoo_request('res.partner.category', 'search_read', [[]],
			{fields => ['name', 'id'], order => 'create_date ASC'});
		defined $categories or die "CRM did not return categories";

		my %odoo_category_id;
		foreach my $category (@$categories) {
			$odoo_category_id{$category->{name}} = $category->{id};
		}

		my %required_category_id;
		foreach my $category_label (@required_category_labels) {
			if (not exists $odoo_category_id{$category_label}) {
				die "Category `$category_label` not found in CRM";
			}
			$tmp_crm_data->{category}{$category_label} = $odoo_category_id{$category_label};
		}

		$crm_data = $tmp_crm_data;
	} or do {
		print STDERR "Failed to load CRM data from Odoo: $@\n";
		if (not defined $crm_data) {
			die "Could not load CRM data from cache";
		}
		print STDERR "CRM data loaded from cache\n";
	};

	store("$BASE_DIRS{CACHE_TMP}/crm_data.sto", $crm_data);

	return;
}

1;

