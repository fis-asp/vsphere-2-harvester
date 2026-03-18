# VMware vSphere Python SDK Community Samples Addons
# Copyright (c) 2014-2021 VMware, Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
This module implements simple helper functions for python samples
"""
import argparse
import getpass

__author__ = "VMware, Inc."


class Parser:
    """
    Samples specific argument parser.
    Wraps argparse to ease the setup of argument requirements for the samples.

    Example:
        parser = cli.Parser()
        parser.add_required_arguments(cli.Argument.VM_NAME)
        parser.add_optional_arguments(cli.Argument.DATACENTER_NAME, cli.Argument.NIC_NAME)
        parser.add_custom_argument(
            '--disk-number', required=True, help='Disk number to change mode.')
        args = parser.get_args()
    """

    def __init__(self):
        """
        Defines two arguments groups.
        One for the standard arguments and one for sample specific arguments.
        The standard group cannot be extended.
        """
        self._parser = argparse.ArgumentParser(description='Arguments for talking to vCenter')
        self._standard_args_group = self._parser.add_argument_group('standard arguments')
        self._specific_args_group = self._parser.add_argument_group('sample-specific arguments')

        # because -h is reserved for 'help' we use -s for service
        self._standard_args_group.add_argument('-s', '--host',
                                               required=False,
                                               action='store',
                                               help='vSphere service address to connect to')

        # because we want -p for password, we use -o for port
        self._standard_args_group.add_argument('-o', '--port',
                                               type=int,
                                               default=443,
                                               action='store',
                                               help='Port to connect on')

        self._standard_args_group.add_argument('-u', '--user',
                                               required=True,
                                               action='store',
                                               help='User name to use when connecting to host')

        self._standard_args_group.add_argument('-p', '--password',
                                               required=False,
                                               action='store',
                                               help='Password to use when connecting to host')

        self._standard_args_group.add_argument('-nossl', '--disable-ssl-verification',
                                               required=False,
                                               action='store_true',
                                               help='Disable ssl host certificate verification')

    def get_args(self):
        """
        Supports the command-line arguments needed to form a connection to vSphere.
        """
        args = self._parser.parse_args()
        return self._prompt_for_password(args)

    def _add_sample_specific_arguments(self, is_required: bool, *args):
        """
        Add an argument to the "sample specific arguments" group
        Requires a predefined argument from the Argument class.
        """
        for arg in args:
            name_or_flags = arg["name_or_flags"]
            options = arg["options"]
            options["required"] = is_required
            self._specific_args_group.add_argument(*name_or_flags, **options)

    def add_required_arguments(self, *args):
        """
        Add a required argument to the "sample specific arguments" group
        Requires a predefined argument from the Argument class.
        """
        self._add_sample_specific_arguments(True, *args)

    def add_optional_arguments(self, *args):
        """
        Add an optional argument to the "sample specific arguments" group.
        Requires a predefined argument from the Argument class.
        """
        self._add_sample_specific_arguments(False, *args)

    def add_custom_argument(self, *name_or_flags, **options):
        """
        Uses ArgumentParser.add_argument() to add a full definition of a command line argument
        to the "sample specific arguments" group.
        https://docs.python.org/3/library/argparse.html#the-add-argument-method
        """
        self._specific_args_group.add_argument(*name_or_flags, **options)

    def set_epilog(self, epilog):
        """
        Text to display after the argument help
        """
        self._parser.epilog = epilog

    def _prompt_for_password(self, args):
        """
        if no password is specified on the command line, prompt for it
        """
        if not args.password:
            args.password = getpass.getpass(
                prompt='"--password" not provided! Please enter password for host %s and user %s: '
                       % (args.host, args.user))
        return args


class Argument:
    """
    Predefined arguments to use in the Parser

    Example:
        parser = cli.Parser()
        parser.add_optional_arguments(cli.Argument.VM_NAME)
    """
    def __init__(self):
        pass

    VM_NAME = {
        'name_or_flags': ['-v', '--vm-name'],
        'options': {'action': 'store', 'help': 'Name of the vm'}
    }

