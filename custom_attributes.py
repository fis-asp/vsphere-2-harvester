#!/usr/bin/env python

"""
Python program to retrieve the custom attributes//custom fields from VMWare virtual machine
"""

import re
from pyVmomi import vim
from tools import pchelper, cli, service_instance
from typing import Any


def get_vm_data() -> dict[str, Any]:
    parser = cli.Parser()
    parser.add_optional_arguments(cli.Argument.VM_NAME)
    parser.add_custom_argument("--endpoint", required=True, help="VSphere Endpoint URL")
    args = parser.get_args()
    endpoint = args.endpoint
    vm_name = args.vm_name
    host = get_host(endpoint)

    service_instance = vsphere_connect(
        host=host, user=args.user, pwd=args.password, nossl=True
    )

    custom_fields = service_instance.content.customFieldsManager.field
    custom_field_keys = {field.name: field.key for field in custom_fields}
    content = service_instance.RetrieveContent()

    vm = pchelper.get_obj(content, [vim.VirtualMachine], vm_name)
    custom_field_data = parse_custom_fields(vm.customValue, custom_field_keys)

    return custom_field_data


def vsphere_connect(
    host: str, user: str, pwd: str, nossl: bool = True
) -> vim.ServiceInstance:
    class Args:
        def __init__(self):
            self.host = host
            self.user = user
            self.password = pwd
            self.port = 443
            self.disable_ssl_verification = nossl

    args = Args()
    return service_instance.connect(args)


def get_host(endpoint: str) -> str:
    # example: https://aspvcenter80.fis-gmbh.de/sdk -> aspvcenter80.fis-gmbh.de
    return endpoint.replace("https://", "").replace("http://", "").split("/")[0]


def parse_custom_fields(
    custom_fields: vim.VirtualMachine.customValue, custom_field_keys: dict[str, int]
) -> dict[str, str]:
    custom_field_data = {
        name: get_field_value(custom_fields, key)
        for name, key in custom_field_keys.items()
    }

    return custom_field_data


def get_field_value(custom_fields: vim.VirtualMachine.customValue, key: int) -> Any:
    try:
        key_field = [field for field in custom_fields if field.key == key][0]
        value = key_field.value
    except IndexError:
        value = None

    return value


def make_k8s_annotation_compliant(key: str) -> str:
    umlaut_map = str.maketrans(
        {"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "AE", "Ö": "OE", "Ü": "UE", "ß": "ss"}
    )

    key = key.strip()
    # Transliterate German umlauts (ä->ae, ö->oe, etc.)
    key = key.translate(umlaut_map)

    # Replace invalid characters (not alphanumeric, dash, underscore, dot) with hyphen
    # e.g. "Owner Name" -> "Owner-Name"
    compliant_key = re.sub(r"[^a-zA-Z0-9\-_.]", "-", key)

    # e.g. "name---" -> "name"
    # e.g. "---name" -> "name"
    compliant_key = re.sub(r"^[^a-zA-Z0-9]+", "", compliant_key)
    compliant_key = re.sub(r"[^a-zA-Z0-9]+$", "", compliant_key)

    if len(compliant_key) > 63:
        compliant_key = compliant_key[:63]
        compliant_key = re.sub(r"[^a-zA-Z0-9]+$", "", compliant_key)

    return compliant_key


if __name__ == "__main__":
    data = get_vm_data()
    for name, value in data.items():
        if value is not None:
            # Convert key to K8s annotation-compliant format
            safe_key = make_k8s_annotation_compliant(str(name))
            print(f"{safe_key}={value}")
