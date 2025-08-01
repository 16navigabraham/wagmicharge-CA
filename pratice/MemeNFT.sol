// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MemeNFT is ERC721URIStorage, Ownable {
    uint256 public nextTokenId;
    event MemeMinted(address indexed to, uint256 indexed tokenId, string metadataUrl);

    constructor() ERC721("MemeNFT", "MEME") Ownable(msg.sender) {}

    function mintMeme(string memory metadataUrl) external {
        uint256 tokenId = ++nextTokenId;
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, metadataUrl);
        emit MemeMinted(msg.sender, tokenId, metadataUrl);
    }
    // No need to override tokenURI, ERC721URIStorage handles it
}
