// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "../interfaces/IPool.sol";

/**
 * @title The PoolFactory
 */
interface IPoolFactory {
    /**
     * @dev Emitted when a pool is created.
     */
    event PoolCreated(address indexed addr);

    /**
     * @dev Creates a pool's PoolAdmin controller
     * @dev Emits `PoolControllerCreated` event.
     */
    function createPool(
        address,
        address,
        address,
        IPoolConfigurableSettings calldata
    ) external returns (address);
}