// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;
//add user , get userdata,delete userdata for survey
contract SimpleStorage {
    struct Userdata {
    address walletaddress;
    string username;

    string socialaccount;
       }
       mapping (string => Userdata) user;
        uint public totalusers = 0; // Add a variable to store the number of users


function getuserdata(string memory _username) public view returns (string memory, address){
    require(user[_username].walletaddress != address(0),"User does not exist");
    return (user[_username].socialaccount,user [_username]. walletaddress);
}

    function adduserdata(string memory _username, address walletaddress,string memory _socialaccount) public {
        user[_username] = Userdata(walletaddress,_username,_socialaccount);
     totalusers++; 
    }
   function removeuserdata(string memory _username) public{
    require(user[_username].walletaddress != address(0),"user does not exist");
    delete user[_username];
}

    function gettotalusers() public view returns (uint){
        return totalusers;
    }

}